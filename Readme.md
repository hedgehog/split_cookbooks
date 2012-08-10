
To update all cookbooks:
    pushd /src/split_cookbooks/
      bundle exec rake 2>1|tee update_all.log
    popd
