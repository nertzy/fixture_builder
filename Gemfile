# frozen_string_literal: true

source "https://rubygems.org"

gemspec

rails_version = ENV.fetch("RAILS_VERSION", ">= 7.2")
rails_branch = ENV.fetch("RAILS_BRANCH", nil)

if rails_branch
  gem "rails", git: "https://github.com/rails/rails.git", branch: rails_branch
else
  gem "rails", rails_version
end
