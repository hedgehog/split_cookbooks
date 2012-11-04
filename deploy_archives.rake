desc 'Deploy archives to AWS Cloudfront'
task :cdn do |t, args|

  conf ||= config
  site = Site.new( conf.fqdn,
                   :path               => "#{config.src_path}",
                   :destroy_old_files  => true,
                   :compress           => '',
                   :access_key_id      => conf.aws_access_key,
                   :secret_key         => conf.aws_secret_key,
                   :distribution_id    => conf.cdn_id )
  site.deploy!
end
