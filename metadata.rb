require 'pathname'
require 'fakefs/safe'
require 'zlib'
require 'xz'
require 'archive/tar/minitar'


class Chef
  module Mixin
    module FromFile

      # Loads a given ruby file from a tar.gz archive, and runs instance_eval against it in the context of the current
      # object.
      #
      # Raises an IOError if the file cannot be found, or is not readable.
      def from_archive(archive, filename)
        metadata_processed = false
        init_problem_hsh
        if File.exists?(archive) && File.readable?(archive)
          contents = extract_file_to_string(archive, filename)
          pp full_archive= ::Pathname.new(archive).expand_path
          pp ckbk_name = full_archive.dirname.basename.to_s
          Dir.mktmpdir {|dir|
            # use the directory...
            Dir.chdir(dir) do |fldr|
              pwd = Pathname(fldr).expand_path
              pp 'now'
              pp pwd
              case File.extname(archive)
                when '.gz'
                  tgz = ::Zlib::GzipReader.new(File.open(full_archive, 'rb'))
                  ::Archive::Tar::Minitar.unpack(tgz, '.')
                when '.xz'
                  ::XZ::StreamReader.open(full_archive) do |txz|
                    ::Archive::Tar::Minitar.unpack(txz, '.')
                  end
              end
              pp 'here'
              subtemps = pwd.children
              subtemps.empty? and raise "The package archive was empty!"
              subtemps.delete_if{|pth| pth.to_s[/pax_global_header/]}
              subtemps.size > 1 and raise "The package archive has too many children!"
              @destination = subtemps.first.basename.to_s
              pp "Cookbook: #{} Depends name: #{@destination}"
              Dir.chdir("#{@destination}") do |dr|
                pp Pathname(dr).expand_path
                if @metadata_rb_problems.key?(ckbk_name)
                  @metadata_rb_problems[ckbk_name].each do |fn|
                    if archive[/#{fn}/]
                      break if (@metadata_json_problems.key?(ckbk_name) && @metadata_rb_problems[ckbk_name].index(fn))
                      metadata_processed = parse_metadata('json')
                      break
                    end
                  end
                  #if !metadata_processed
                  #  # We cannot generate a json manifest from metadata.rb|json so
                  #  # try knife
                  #  pp '='*80
                  #  pp '='
                  #  pp '= Warning the metadata contents here could be problematic.'
                  #  pp "= #{@destination} #{archive}"
                  #  pp '='
                  #  pp '='*80
                  #  `knife cookbook metadata from file #{Dir.pwd}/metadata.rb`
                  #  metadata_processed = parse_metadata('json')
                  #  # otherwise someone will get bitten...
                  #  if !metadata_processed
                  #    raise "Could not parse metadata files required to create manifest: #{archive}"
                  #  end
                  #end
                else
                  # we don't seems to have problematic metadata files
                  metadata_processed = parse_metadata('rb')
                end
                #if !metadata_processed
                #  metadata_processed = parse_metadata('rb')
                #end
              end
            end
          }
        else
          raise IOError, "Cannot open or read #{filename}!"
        end
        metadata_processed
      end

      def parse_metadata(ext)
        result = false
        fn = "#{Dir.pwd}/metadata.#{ext}"
        if File.exists?(fn) && File.readable?(fn)
          str = File.open(fn, 'r').read
          eval_str = case ext
                  when 'json'
                    "JSON.parse(#{str})"
                  when 'rb'
                    str
                     end
          begin
            self.instance_eval(eval_str, "metadata.#{ext}", 1)
            self.depends_name = @destination
          rescue => e
            pp e.message
            pp e.backtrace.join('/n')
          end
          result = true
        else
          raise "Cannot read file #{fn}"
        end
        result
      end

      def init_problem_hsh
        @metadata_json_problems ||= {'oc-chef' => ['qa-0.15.0.tar.xz']
                                     }
        @metadata_rb_problems   ||= {'oc-chef' => ['qa-0.15.0.tar.xz']
                                    }
      end

      def extract_file_to_string(archive, file)
        case File.extname(file)
          when '.gz'
            return extract_tar_gz(archive, file)
          when '.xz'
            return extract_tar_xz(archive, file)
        end
      end

      def extract_tar_gz(archive, file)
        zr = ::Zlib::GzipReader.new(File.open(archive, 'rb'))
        Archive::Tar::Minitar::Reader.new(zr).each do |e|
          next unless e.file?
          if e.full_name[/#{file}$/]
            return e.read
          end
        end
      end

      def extract_tar_xz(archive, file)
        ::XZ::StreamReader.open(full_archive) do |txz|
          Archive::Tar::Minitar::Reader.new(zr).each do |e|
            next unless e.file?
            if e.full_name[/#{file}$/]
              return e.read
            end
          end
        end
      end
    end
  end
end
