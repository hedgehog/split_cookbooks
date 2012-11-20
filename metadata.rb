require 'fakefs/safe'
require 'zlib'
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
          #pp contents
          pp destination = File.basename(File.dirname(archive))
          tgz = ::Zlib::GzipReader.new(File.open(archive, 'rb'))
          Dir.mktmpdir {|dir|
            # use the directory...
            Dir.chdir(dir) {
              ::Archive::Tar::Minitar.unpack(tgz, 'xyz')
              Dir.chdir("xyz/#{destination}") do |dr|
                if @metadata_rb_problems.key?(destination)
                  @metadata_rb_problems[destination].each do |fn|
                    if archive[/#{fn}/]
                      break if (@metadata_json_problems.key?(destination) && @metadata_rb_problems[destination].index(fn))
                      metadata_processed = parse_metadata('json')
                      break
                    end
                  end
                  if !metadata_processed
                    # We cannot generate a json manifest from metadata.rb|json so
                    # try knife
                    pp '='*80
                    pp '='
                    pp '= Warning the metadata contents here could be problematic.'
                    pp "= #{destination} #{archive}"
                    pp '='
                    pp '='*80
                    `knife cookbook metadata from file #{Dir.pwd}/metadata.rb`
                    metadata_processed = parse_metadata('json')
                    # otherwise someone will get bitten...
                    if !metadata_processed
                      raise "Could not parse metadata files required to create manifest: #{archive}"
                    end
                  end
                else
                  # we don't seems to have problematic metadata files
                  metadata_processed = parse_metadata('rb')
                end
                if !metadata_processed
                  metadata_processed = parse_metadata('rb')
                end
              end
            }
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
          self.instance_eval(eval_str, "metadata.#{ext}", 1)
          result = true
        else
          raise "Cannot read file #{fn}"
        end
        result
      end

      def init_problem_hsh
        @metadata_json_problems ||= {'ap-cookbook-dbench' => ['0.0.1.tar.gz',
                                                              '0.0.4.tar.gz']
                                     }
        @metadata_rb_problems   ||= {}
      end

      def extract_file_to_string(archive, file)
        zr = ::Zlib::GzipReader.new(File.open(archive, 'rb'))
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
