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
    # used to decide what needs to be deployed. Also build JSON files (per Chef-API)
    # which function as version indexes for Librarian-chef.
    def build_index
      puts "Building index:"
      @cookbook_index = {}
      prev_path = false
      Dir['**/*'].sort.each do |path|
        if File.directory?( path )
          build_cookbook_index(prev_path) if prev_path
          start_cookbook_index(path)
          puts "  #{path}"
          prev_path = path
        else
          puts "    #{path}"
          cookbook, file = path.split(/\//)
          @index[path] = ::Digest::MD5.file(path).to_s
          # Don't index .json or .zip files
          unless path[/\.(json|zip)$/]
            append_cookbook_index(path)
            build_cookbook_metadata(cookbook, path)
          end
        end
      end
    end

    def start_cookbook_index(path)
      pp "Start indexing cookbook: #{path}"
      cookbook, file = path.split(/\//)
      @cookbook_index[cookbook] = { :name => cookbook, :versions => [] }
    end

    def append_cookbook_index(path)
      cookbook, file = path.split(/\//)
      @cookbook_index[cookbook][:versions] << "www.cookbooks.io/#{path}"
    end

    def extract_version(file, ext = '.zip')
      File.basename(file, ext)
    end

    def build_cookbook_index(path)
      cookbook, file = path.split(/\//)
      cookbook_json = "#{cookbook}.json"
      hsh = @cookbook_index[cookbook]
      puts "  Build index JSON: #{cookbook}"
      puts "    name: #{hsh[:name]}"
      puts "    # versions: #{hsh[:versions].size}"
      Pathname.new(cookbook_json).open('wb') { |f| f.write(JSON.dump(hsh)) }
      @index[cookbook_json] = ::Digest::MD5.file(cookbook_json).to_s
    end

    def build_cookbook_metadata(name, path)
      filename  = File.basename(path,".*")
      metadata_json = File.join( File.dirname(path), "#{filename}.json" )
      # Read metadata.rb extracted from the archive pointed to by path.
      hsh = compile_manifest(name, path)
      Pathname.new(metadata_json).open('wb') { |f| f.write(JSON.dump(hsh)) }
    end

    def compile_manifest(name, archive)
      # Inefficient, if there are many cookbooks with uncompiled metadata.
      require 'chef/json_compat'
      require 'chef/cookbook/metadata'
      md = ::Chef::Cookbook::Metadata.new
      md.name(name)
      md.from_archive(archive.to_s, 'metadata.rb')
      pp '='*80
      pp md
      pp man = {'name' => md.name, 'version' => md.version, 'dependencies' => md.dependencies}
      man
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
      pp path
      ext = File.extname(path).gsub(/\./,'')
      pp ext
      cmp = 'gzip' if @site.compress.include?(ext)
      @directory.files.create :key => path,
                              :body => File.open( path ),
                              :public => true,
                              :content_encoding => cmp
    end

    # Compose and post a cache invalidation request to CloudFront. This will
    # ensure that all CloudFront distributions get the latest content quickly.
    def invalidate_cache( distribution_id )
      unless @updated_paths.empty?
        puts "Invalidating cached copy of: #{@updated_paths}"
        cdn.post_invalidation distribution_id, @updated_paths
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
  end
end


