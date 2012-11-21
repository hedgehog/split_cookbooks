require 'json'
require 'fog'

def config
  @config ||= ::Hashie::Mash.new(YAML.load_file(File.join(Rake.original_dir, 'config.yml')))
end

###
#
# Site represents a site to be deployed to S3 and CloudFront. This object
# is a simple data structure, which is deployed with a `FogSite::Deployer`
#
module MetaDataSingletonMethods

  def depends_name(name)
    @depends_name = name
  end

  def depends_name
    @depends_name
  end
end

class Site
  attr_reader :domain_name
  attr_writer :access_key_id, :secret_key
  attr_accessor :compress, :distribution_id, :destroy_old_files, :path
                attr_accessor :build_engine

  def initialize( domain_name, attributes_map = {} )
    @domain_name = domain_name
    attributes_map.each do |name, val|
      pp "#{name} #{val}"
      setter = (name.to_s + "=").to_sym
      self.send(setter, val)
    end
    @destroy_old_files = true
  end

  BUNDLER_VARS = %w(BUNDLE_GEMFILE RUBYOPT GEM_HOME BUNDLE_BIN_PATH)
  def with_clean_env
    begin
      bundled_env = ENV.to_hash
      BUNDLER_VARS.each{ |var| ENV.delete(var) }
      yield
    ensure
      ENV.replace(bundled_env.to_hash)
    end
  end

  def access_key_id
    @access_key_id ||= config.aws_access_key
  end

  def secret_key
    @secret_key ||= config.aws_secret_key
  end

  def deploy!
    Deployer.run(self)
  end

  # Used to actually execute a deploy. This object is not safe for reuse - the
  # `@index` and `@updated_paths` stay dirty after a deploy to allow debugging
  # and inspection by client scripts.
  class Deployer
    attr_reader :index, :updated_paths
    class UsageError < ::StandardError ; end

    # Run a single deploy. Creates a new `Deployer` and calls `run`.
    def self.run( site, options = {} )
      deployer = Deployer.new( site )
      deployer.run
    end

    def initialize( site )
      @site = site
      @index = {}
      @cookbook_index = {}
      @updated_paths = []
      @signed_url = ''
    end

    # Validate our `Site`, create a and configure a bucket, build the index,
    # sync the files and (finally) invalidate all paths which have been updated
    # on the content distribution network.
    def run
      validate
      make_directory
      pp @site
      Dir.chdir @site.path do
        build_index
        sync_remote
        pp @site.distribution_id = find_distribution(@site.domain_name)['Id']
        if( @site.distribution_id )
          invalidate_cache(@site.distribution_id)
        end
        signed_url
      end
    end

    def signed_url
      bucket = @site.domain_name
      puts "Using bucket: #{bucket}"
      expires_at = Time.now + (24 * 60 * 60)
      site_path = "/" # This returns https://s3.amazonaws.com/alpha.taqtiqa.com/
      signed_url = connection.directories.get(bucket).files.get_https_url(site_path, expires_at)
      puts "Signed URL (24hrs (#{expires_at}): #{signed_url}"

    end

    def validate
      assert_not_nil @site.access_key_id, "No AccessKeyId specified"
      assert_not_nil @site.secret_key, "No SecretKey specified"
    end

    # Creates an S3 bucket for web site serving, using `index.html` and
    # `404.html` as our special pages.
    def make_directory
      bucket = @site.domain_name
      @directory = connection.directories.get(bucket)
      if @directory.nil?
        puts "Creating bucket: #{bucket}"
        @directory = connection.directories.create :key => bucket,
                                                   :public => true
        connection.put_bucket_website(bucket, 'index.html', :key => '404.html')
      end
      puts "Using bucket: #{bucket}"
    end

    # Build an index of all the local files and their md5 sums. This will be
    # used to decide what needs to be deployed.
    # Also build JSON files (per Chef-API) which function as version indexes
    # for Librarian-chef. IF no metadat files can be parsed to generate the
    # manifest required by Librarian-chef then the cookbook+archive are added
    # to the exclusion list @skip_cookbook.
    def build_index
      puts "Building index:"
      @cookbook_index = {}
      init_skip_cookbooks
      prev_path = false
      Dir['**/*'].each do |path|
        if File.directory?( path )
          build_cookbook_index(prev_path) if prev_path
          start_cookbook_index(path)
          puts "  #{path}"
          prev_path = path
        else
          cookbook, file = path.split(/\//)
          if @skip_cookbooks.index(path)
            puts "Skipping #{path}"
            next
          end
          # Rakefile task only tags as qa- those with version metadata.
          # Index for S3 upload files that:
          # - do start `qa-` and do end `.tar.xz`
          # - do not start `qa-` and do end `.json`
          if path[/\.json$/] || path[/(qa-.*)(\.tar\.xz$)/]
            puts "    #{path}"
            @index[path] = ::Digest::MD5.file(path).to_s
          elsif (!path[/qa-/] && path[/\.tar\.gz$/]) || path[/\.zip$/]
            # Delete/cleanup files that:
            # - do not start `qa-` and do end `.taq.gz`
            # - do start `qa-` and do end `.tar.gz`
            # - do end `.zip`
            if File.exist?(path)
              FileUtils.rm(path)
            end
          end
          # Only `qa-` tags have metadata version information.
          # Don't Librarian-chef index files that:
          # - do end `.json`
          # - do end `.zip`
          # - do not start `qa-` and do end `.taq.gz`
          if !path[/\.zip$/] && !path[/\.json$/] && !(!path[/qa-/] && path[/\.tar\.gz$/])
            append_cookbook_versions(path)
            build_cookbook_metadata(cookbook, path)
          end
        end
      end
    end

    def start_cookbook_index(path)
      cookbook, file = path.split(/\//)
      puts "Start indexing cookbook: #{cookbook} file: #{file}"
      @cookbook_index[cookbook] = { :name => cookbook, :versions => [] }
    end

    def append_cookbook_versions(path)
      cookbook, file = path.split(/\//)
      case File.extname(file)
        when '.gz'
          tag = "#{File.basename(file,'.tar.gz')}.json"
        when '.xz'
          tag = "#{File.basename(file,'.tar.xz')}.json"
      end
      puts "     cookbook: #{cookbook} file: #{tag}"
      @cookbook_index[cookbook][:versions] << "http://www.cookbooks.io/#{cookbook}/#{tag}"
    end

    def extract_version(file, ext = '.xz')
      prefix, version = ::File.basename(file, ext).to_s[/(qa-).*/]
      version
    end

    def extract_depends_name(archive)
      ::XZ::StreamReader.open(archive) do |txz|
        ::Archive::Tar::Minitar::Reader.new(txz).each do |e|
          next if e.file?
          next if e.dirname[/pax_global_header/]
          return e.full_name.to_s
        end
      end
    end

    def build_cookbook_index(path)
      cookbook, file = path.split(/\//)
      cookbook_json = "#{cookbook}.json"
      hsh = @cookbook_index[cookbook]
      puts "  Build index JSON: #{cookbook}"
      puts "    name: #{hsh[:name]}"
      puts "    # versions: #{hsh[:versions].size}"
      if hsh[:versions]
        puts "Sorted 'versions' data:"
        list = []
        hsh[:versions].each do |v|
          list.push(::Version.new(v))
        end
        hsh[:versions] = list.sort
      else
        puts "No 'versions' data: #{hsh}"
      end
      hsh[:versions].each do |ver|
        puts "                 #{ver}"
      end
      hsh['depends_name'] = @depends_name
      Pathname.new(cookbook_json).open('w') { |f| f.write(JSON.dump(hsh)) }
      @index[cookbook_json] = ::Digest::MD5.file(cookbook_json).to_s
    end

    class ::Version
      # Source: http://www.dzone.com/snippets/ruby-class-easy-version-number
      include ::Comparable

      attr_reader :major, :feature_group, :feature, :bugfix

      def initialize(str="")
        @lead, @prefix, version, @suffix = str.split(/^(.*qa-)(.*)(\.json)/)
        v = version.split(".")
        @major = v[0].to_i
        @feature_group = v[1].to_i if v.size >= 2
        @feature = v[2].to_i if v.size >= 3
        @bugfix = v[3].to_i if v.size >= 4
      end

      def <=>(other)
        return @major <=> other.major if ((@major <=> other.major) != 0)
        return @feature_group <=> other.feature_group if ((@feature_group <=> other.feature_group) != 0)
        return @feature <=> other.feature if ((@feature <=> other.feature) != 0)
        return @bugfix <=> other.bugfix
      end

      def self.sort
        self.sort!{|a,b| a <=> b}
      end

      def to_s
        str = @lead + @prefix + @major.to_s
        str << ".#{@feature_group.to_s}" if @feature_group
        str << ".#{@feature.to_s}" if @feature
        str << ".#{@bugfix.to_s}" if @bugfix
        str << @suffix
      end
    end

    def build_cookbook_metadata(name, path)
      case File.extname(path)
        when '.gz'
          filename  = File.basename(path, '.tar.gz')
        when '.xz'
          filename  = File.basename(path, '.tar.xz')
      end
      metadata_json = File.join( File.dirname(path), "#{filename}.json" )
      # Read metadata.rb extracted from the archive pointed to by path.
      hsh = compile_manifest(name, path)
      # Set depends name to be written to cookbook index file
      @depends_name = hsh['depends_name']
      ::Pathname.new(metadata_json).open('wb') { |f| f.write(JSON.dump(hsh)) }
    end

    def compile_manifest(name, archive)
      # Inefficient, if there are many cookbooks with uncompiled metadata.
      require 'chef/json_compat'
      require 'chef/cookbook/metadata'
      md = ::Chef::Cookbook::Metadata.new
      # TODO: consider using 'replaces' from metadata here instead of name or inserting
      # The `depends_name` is a custom attr to pass this data back to the scope of
      # the calling method
      #md.extend(MetaDataSingletonMethods)
      class << md
        attr_accessor :depends_name
      end
      md.name(name)
      md.from_archive(archive.to_s, 'metadata.rb')
      pp man = {'name' => md.name,
                'depends_name' => md.depends_name,
                'version' => md.version,
                'file' => "http://www.cookbooks.io/#{archive.to_s}",
                'dependencies' => md.dependencies}
      man
    end

    # Return this cookbook's name as shown in any other cookbooks `depends` listing
    # Hierachy:
    # replaces (from metadata)
    # lookup from upstream definition file
    def depends_name(metadata)
      #if metadata.replacing
      #  return metadata.replacing
      #else
      #  # TODO: lookup depends_name from upstream yml file
      #  return metadata.name
      #end
    end

    # Synchronize our local copy of the site with the remote one. This uses the
    # index to detect what has been changed and upload only new/updated files.
    # Helpful debugging information is emitted, and we're left with a populated
    # `updated_paths` instance variable which can be used to invalidate cached
    # content.
    def sync_remote
      @directory.files.each do |remote_file|
        # pp remote_file
        #binding.pry
        perm = case ENV['TAQTIQA_ENVIRONMENT']
                 when 'production'
                   'public-read'
                 else
                   'public-read'
               end
        remote_file.acl = perm
        path = remote_file.key
        local_file_md5 = @index[path]

        if local_file_md5.nil? and @site.destroy_old_files
          # Don't destroy remote log files
          unless path.match /^log\//
            puts "#{path}: deleted"
            remote_file.destroy
            @updated_paths << ("/" + path)
          else
            puts "#{path}: retained"
          end
        elsif local_file_md5 == remote_file.etag
          puts "#{path}: unchanged"
          @index.delete( path )
        else
          puts "#{path}: updated"
          write_file( path )
          @index.delete( path )
          @updated_paths << ("/" + path)
        end
      end

      @index.each do |path, md5|
        puts "#{path}: new (#{md5})"
        write_file( path )
      end
    end

    # Push a single file out to S3.
    def write_file( path )
      cmp = nil
      # pp path
      ext = File.extname(path).gsub(/\./,'')
      # pp ext
      cmp = 'gzip' if @site.compress.include?(ext)
      @directory.files.create :key => path,
                              :body => File.open( path ),
                              :public => true,
                              :content_encoding => cmp
    end

    # Compose and post a cache invalidation request to CloudFront. This will
    # ensure that all CloudFront distributions get the latest content quickly.
    # Note:
    #  - 1000 items can be invalidated in one request.
    #  - Up to 3 concurrent requests can be issued.
    # Reference:
    # - http://aws.amazon.com/cloudfront/faqs/#Is_there_a_limit_to_the_number_of_invalidation_requests

    def invalidate_cache( distribution_id )
      unless @updated_paths.empty?
        @updated_paths.each_slice(1000).to_a.each do |ary|

          #
          # Suspending since AWS charges $5/1000 invalidation requests per month!
          #

          #puts "Invalidating cached copy of: #{ary}"
          #resp = cdn.post_invalidation distribution_id, ary
          #puts "Done. Response:"
          #puts resp.body
        end
      end
    end

    def cdn
      @cdn ||= ::Fog::CDN.new( credentials )
    end

    def find_distribution(fqdn)
      # likely fails if cname already exists in another distribution
      cdn_list = cdn.get_distribution_list
      cdnl = cdn_list.body['DistributionSummary']
      return_cdn = nil
      @unmatched = true
      cdnl.each { |cdn| ( @unmatched = false; return_cdn = cdn ) if cdn['CNAME'][0] == fqdn }
      return_cdn
    end

    def connection
      @connection ||= ::Fog::Storage.new( credentials )
    end

    def credentials
      {
          :provider              => 'AWS',
          :aws_access_key_id     => @site.access_key_id,
          :aws_secret_access_key => @site.secret_key
      }
    end

    def assert_not_nil( value, error )
      raise UsageError.new( error ) unless value
    end

    def init_skip_cookbooks
      # see for example
      # yumrepo:  https://tickets.opscode.com/browse/CHEF-2326
      @skip_cookbooks ||= [
        'ap-cookbook-yumrepo/qa-0.0.1.tar.gz',
        'ap-cookbook-yumrepo/qa-0.0.2.tar.gz',
        'ap-cookbook-yumrepo/qa-0.0.3.tar.gz',
        'ap-cookbook-yumrepo/qa-0.0.4.tar.gz',
        'ap-cookbook-yumrepo/qa-0.0.6.tar.gz',
        'ap-cookbook-yumrepo/qa-0.0.8.tar.gz',
        'ap-cookbook-yumrepo/qa-0.10.0.tar.gz',
        'ap-cookbook-yumrepo/qa-0.10.1.tar.gz',
        'ap-cookbook-yumrepo/qa-0.11.0.tar.gz',
        'ap-cookbook-yumrepo/qa-0.11.1.tar.gz',
        'ap-cookbook-yumrepo/qa-0.11.2.tar.gz',
        'ap-cookbook-yumrepo/qa-0.12.0.tar.gz',
        'ap-cookbook-yumrepo/qa-0.12.4.tar.gz',
        'ap-cookbook-yumrepo/qa-0.16.2.tar.gz',
        'ap-cookbook-yumrepo/qa-0.16.3.tar.gz',
        'ap-cookbook-yumrepo/qa-0.16.4.tar.gz',
        'mc-hostname/qa-0.0.2.tar.gz',
        'mc-hostname/qa-0.2.2.tar.gz',
        'oc-chef/qa-0.15.0.tar.gz',
        'oc-chef/qa-0.19.0.tar.gz',
        'rs-repo_git/qa-0.1.0.tar.gz',
        'rs-rs_utils/qa-0.1.0.tar.gz',
        'rs-web_apache/qa-0.1.0.tar.gz'
      ]
    end
  end
end

