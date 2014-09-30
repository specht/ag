#!/usr/bin/env ruby

tag = `git tag | sort | tail -n 1`.strip
puts "Publishing Ag #{tag}..."

system("dput ppa:micha-specht/ag _build/ag_#{tag}_source.changes")
