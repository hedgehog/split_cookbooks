To create API token (CLI):

  curl -u 'hedgehog' -d '{"scopes":["delete_repo","public_repo","repo","user"],"note":"Cookbooks Rake tasks"}' https://api.github.com/authorizations

This token must be placed in the config.yml file, which is not kept in this repo.
Example config.yml content:

---
login: hedgehog
token: XXXXXXXXXXXX
url: https://api.github.com/authorizations/NNNNNN
org: cookbooks

To update all cookbooks:
  pushd /src/split_cookbooks/
    bundle exec rake 2>&1|tee update_all.log
    bundle exec rake cdn 2>&1|tee deploy_cdn.log
  popd


TODO:
- Create archives from Git tags & upload to Cloudfront
  http://systemoverlord.com/blog/2011/07/16/automatically-creating-archives-git-tags
