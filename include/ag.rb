require 'date'
require 'highline/import'
require 'json'
require 'open3'
require 'rugged'
require 'set'
require 'tempfile'
require 'webrick'
require 'yaml'

require 'ag/autocomplete'
require 'ag/pager'

class Ag
    
    def initialize()
        srand()
        
        @config = Rugged::Config.global.to_hash
        
        @editor = 'nano'
        @editor = ENV['EDITOR'] if ENV['EDITOR']

        if !['web', 'new', 'edit', 'rm'].include?(ARGV.first)
            run_pager()
        end
        
        begin
            @repo = Rugged::Repository.new(Rugged::Repository.discover(Dir::pwd()))
        rescue Rugged::RepositoryError => e
            puts e unless ENV.include?('COMP_LINE')
            exit(1)
        end
        
        handle_auto_completion() if ENV.include?('COMP_LINE')
        
        if Rugged::Branch.lookup(@repo, '_ag')
            ensure_git_hook_present()
        end
        
        case ARGV.first
        when 'new'
            new_issue(ARGV[1])
        when 'show'
            show_issue(ARGV[1])
        when 'edit'
            edit_issue(ARGV[1])
        when 'rm'
            rm_issue(ARGV[1])
        when 'start'
            start_working_on_issue(ARGV[1])
        when 'oneline'
            oneline(ARGV[1])
        when 'list'
            list_issues()
        when 'search'
            search(ARGV[1, ARGV.size - 1])
        when 'web'
            web()
        when 'log'
            log()
        when 'help', '--help', '-h'
            help()
        end
    end
    
    def handle_auto_completion()
        parts = ENV['COMP_LINE'].split(' ')
        parts.shift()
        AutoComplete::define(parts) do |ac|
            
            # all simple commands
            ['list', 'web', 'help', 'search', 'log'].each do |command|
                ac.option(command)
            end
            
            # all commands which require a current issue ID
            ['new', 'show', 'edit', 'start', 'oneline', 'rm'].each do |command|
                ac.option(command) do |ac|
                    all_tags(false).each do |tag|
                        issue = load_issue(tag)
                        ac.option(issue[:slug])
                    end
                end
            end
            
            # special treatment for 'reparent' command
            ['reparent'].each do |command|
                ac.option(command) do |ac|
                    all_tags(false).each do |tag|
                        issue = load_issue(tag)
                        ac.option(issue[:slug]) do |ac2|
                            all_tags(false).each do |tag2|
                                issue2 = load_issue(tag2)
                                ac2.option(issue2[:slug])
                            end
                            ac2.option('null')
                        end
                    end
                end
            end
        end
        exit 0
    end
    
    def ensure_git_hook_present()
        hook_path = File::join(@repo.path, 'hooks', 'prepare-commit-msg')
        unless File::exists?(hook_path)
            File::open(hook_path, 'w') do |f|
                f.write(File::read(File::join(File.expand_path(File.dirname(__FILE__)), 'prepare-commit-msg.txt')))
            end
            File::chmod(0755, hook_path)
        end
    end

    # return all tags already assigned, with its most recent commit sha1
    # if recursive == true, this includes tags which have already
    # been removed (walks entire history of _ag branch, if present)
    def all_tags_with_sha1(recursive = true)
        tags = {}
        
        ag_branch = Rugged::Branch.lookup(@repo, '_ag')
        if ag_branch
            walker = Rugged::Walker.new(@repo)
            walker.push(ag_branch.target)
            walker.each do |commit|
                commit.tree.each_blob do |blob|
                    tag = blob[:name]
                    tags[tag] ||= commit.oid
                end
                break unless recursive
            end
        end
        
        return tags
    end

    def all_tags(recursive = true)
        tags = all_tags_with_sha1(recursive)
        return Set.new(tags.keys)
    end

    def gen_tag()
        existing_tags = all_tags(true)
        loop do
            result = ''
            2.times { result += (rand(26) + 'a'.ord).chr }
            4.times { result += (rand(10) + '0'.ord).chr }
            return result if !existing_tags.include?(result)
        end
    end
    
    def call_editor(template)
        file = Tempfile.new('ag')
        contents = ''
        begin
            File::open(file.path, 'wb') do |f|
                f.write(template)
            end
            system("#{@editor} #{file.path}")
            File::open(file.path, 'rb') do |f|
                contents = f.read()
            end
        ensure
            file.close
            file.unlink
        end
        return contents
    end

    def parse_issue(s, tag)
        tag = tag[0, 6]
        original = s.dup
        
        lines = s.split("\n")
        if lines[0].index('Summary:') != 0
            raise 'Missing summary field in issue'
        end
        
        summary = lines[0].sub('Summary:', '').strip
        lines.delete_at(0)
        
        parent = nil
        if !lines.empty? && lines[0].index('Parent:') == 0
            parent = lines[0].sub('Parent:', '').strip
            parent = nil if parent == 'null'
            lines.delete_at(0)
        end
        
        description = lines.join("\n")
        description.strip!
        
        summary_pieces = summary.downcase.gsub(/[^a-z0-9]/, ' ').split(' ').select { |x| !x.strip.empty? }[0, 8]
        slug = "#{tag}-#{summary_pieces.join('-')}"

        
        return {:tag => tag, :original => original, :parent => parent,
                :summary => summary, :description => description, :slug => slug}
    end

    def load_issue(tag)
        tag = tag[0, 6]
        ag_branch = Rugged::Branch.lookup(@repo, '_ag')
        if ag_branch
            walker = Rugged::Walker.new(@repo)
            walker.push(ag_branch.target)
            walker.each do |commit|
                commit.tree.each_blob do |blob|
                    test_tag = blob[:name]
                    if test_tag == tag
                        issue = parse_issue(@repo.lookup(blob[:oid]).content, tag)
                        return issue
                    end
                end
            end
        end
        raise "No such issue: [#{tag}]."
    end
    
    def find_commits_for_issues()
        results = {}
        walker = Rugged::Walker.new(@repo)
        walker.push(@repo.head.target)
        walker.each do |commit|
            message = commit.message
            if message =~ /^\[[a-z]{2}\d{4}\]/
                tag = message[1, 6]
                results[tag] ||= {
                    :count => 0,
                    :time_min => commit.time,
                    :time_max => commit.time,
                    :authors => Set.new()
                }
                results[tag][:count] += 1
                results[tag][:authors] << "#{commit.author[:name]} <#{commit.author[:email]}>"
                results[tag][:time_min] = commit.time if commit.time < results[tag][:time_min]
                results[tag][:time_max] = commit.time if commit.time > results[tag][:time_max]
            end
        end
        return results
    end

    def list_issues()
        commits_for_issues = find_commits_for_issues()
        all_issues = {}
        tags_by_parent = {}
        all_tags(false).each do |tag|
            issue = load_issue(tag)
            all_issues[tag] = issue
            tags_by_parent[issue[:parent]] ||= []
            tags_by_parent[issue[:parent]] << tag
        end
        
        def print_tree(parent, all_issues, tags_by_parent, commits_for_issues, prefix = '')
            count = tags_by_parent[parent].size
            tags_by_parent[parent].sort do |a, b|
                    issue_a = all_issues[a]
                    issue_b = all_issues[b]
                    issue_a[:summary].downcase <=> issue_b[:summary].downcase
                end.each_with_index do |tag, index|
                issue = all_issues[tag]
                box_art = ''
                if parent
                    if index < count - 1
                        box_art = "\u251c\u2500\u2500"
                    else
                        box_art = "\u2514\u2500\u2500"
                    end
                end
                puts "[#{tag}] #{commits_for_issues.include?(tag) ? '*' : ' '} #{prefix}#{box_art}#{issue[:summary]}"
                if tags_by_parent.include?(tag)
                    print_tree(tag, all_issues, tags_by_parent, commits_for_issues, parent ? prefix + (index < count - 1 ? "\u2502  " : "   ") : prefix)
                end
            end
        end

        if tags_by_parent[nil]
            print_tree(nil, all_issues, tags_by_parent, commits_for_issues)
        end
    end

    def show_issue(tag)
        tag = tag[0, 6]
        issue = load_issue(tag)
        ol = get_oneline(tag)
        puts '-' * ol.size
        puts ol
        puts '-' * ol.size
        puts issue[:original]
    end
    
    def get_oneline(tag)
        tag = tag[0, 6]
        issue = load_issue(tag)
        parts = [issue[:summary]]
        p = issue
        while p[:parent]
            p = load_issue(p[:parent])
            parts.unshift(p[:summary])
        end
        return "[#{tag}] #{parts.join(' / ')}"
    end
    
    def oneline(tag)
        tag = tag[0, 6]
        puts get_oneline(tag)
    end
    
    def issue_to_s(issue)
        result = ''
        
        result += "Summary: #{issue[:summary]}\n"
        result += "Parent: #{issue[:parent]}\n" if issue[:parent]
        result += "\n"
        result += issue[:description]
        
        return result
    end

    # commit an issue OR delete it if issue == nil && really_delete == true
    def commit_issue(tag, issue, comment, really_delete = false)
        tag = tag[0, 6]
        index = Rugged::Index.new
        begin
            @repo.rev_parse('_ag').tree.each_blob do |blob|
                unless blob[:name] == tag
                    index.add(:path => blob[:name], :oid => blob[:oid], :mode => blob[:filemode])
                end
            end
        rescue Rugged::ReferenceError => e
            # There's no _ag branch yet, but don't worry. It just means we don't
            # have any files to add yet
        end

        if issue
            oid = @repo.write(issue_to_s(issue), :blob)
            index.add(:path => tag, :oid => oid, :mode => 0100644)
        else
            unless really_delete
                puts "Ag internal error: No issue passed to commit_issue, yet really_delete is not true."
                exit(2)
            end
        end

        options = {}
        options[:tree] = index.write_tree(@repo)

        options[:author] = { :email => @config['user.email'], :name => @config['user.name'], :time => Time.now }
        options[:committer] = { :email => @config['user.email'], :name => @config['user.name'], :time => Time.now }
        if issue
            options[:message] ||= "#{comment} [#{tag}]: #{issue[:summary]}"
        else
            options[:message] ||= "#{comment} [#{tag}]"
        end
        options[:parents] = []
        if Rugged::Branch.lookup(@repo, '_ag')
            options[:parents] = [ @repo.rev_parse_oid('_ag') ].compact
            options[:update_ref] = 'refs/heads/_ag'
        end

        commit = Rugged::Commit.create(@repo, options)
        
        unless Rugged::Branch.lookup(@repo, '_ag')
            @repo.create_branch('_ag', commit)
        end
        
    end

    def new_issue(parent_tag)
        parent_tag = parent_tag[0, 6] if parent_tag
        tag = gen_tag()
        
        if parent_tag
            begin
                parent_issue = load_issue(parent_tag)
            rescue 
                puts "Error: Invalid parent issue: #{parent_tag}."
                exit(1)
            end
        end
        
        template = "Summary: "
        if parent_tag
            template += "\nParent: #{parent_tag}"
        end
        issue = parse_issue(call_editor(template), tag)
        
        if issue[:summary].empty?
            raise "Aborting due to empty summary."
        end
        
        if parent_tag
            issue[:parent] = parent_tag
        end
        
        commit_issue(tag, issue, "Added issue")
        puts "Created new issue ##{tag}: #{issue[:summary]}"
    end

    def edit_issue(tag)
        tag = tag[0, 6]
        issue = load_issue(tag)
        
        modified_issue = call_editor(issue[:original])
        if modified_issue != issue[:original]
            issue = parse_issue(modified_issue, tag)
            
            commit_issue(tag, issue, 'Modified issue')
            puts "Modified issue ##{tag}: #{issue[:summary]}"
        else
            puts "Leaving issue ##{tag} unchanged: #{issue[:summary]}"
        end
    end
    
    def rm_issue(tag)
        tag = tag[0, 6]
        issue = load_issue(tag)
        
        puts "Removing issue: #{get_oneline(tag)}"
    
        # If this issue has currently any children, we shouldn't remove it
        all_tags(false).each do |check_tag|
            check_issue = load_issue(check_tag)
            if check_issue[:parent] == tag
                puts "Error: This issue has children, unable to continue."
                exit(1)
            end
        end
        
        response = ask("Are you sure you want to remove this issue [y/N]? ")
        if response.downcase == 'y'
            commit_issue(tag, nil, 'Removed issue', true)
            puts "Removed issue ##{tag}."
        else
            puts "Leaving issue ##{tag} unchanged."
        end
    end
    
    def start_working_on_issue(tag)
        tag = tag[0, 6]
        issue = load_issue(tag)
        # if there's already a branch handling this issue, maybe don't create a new branch?
        system("git checkout -b #{issue[:slug]}")
    end
    
    def search(keywords)
        all_tags(true).each do |tag|
            issue = load_issue(tag)
            found_something = false
            keywords.each do |keyword|
                if issue[:original].downcase.include?(keyword.downcase)
                    puts get_oneline(tag)
                end
            end
        end
    end
    
    def web()
        root = File::join(File.expand_path(File.dirname(__FILE__)), 'web')
        server = WEBrick::HTTPServer.new(:Port => 19816, :DocumentRoot => root)
        
        trap('INT') do 
            server.shutdown()
        end
        
        server.mount_proc('/update-parent') do |req, res|
            parts = req.unparsed_uri.split('/')
            tag = parts[2]
            parent_tag = parts[3]
            issue = load_issue(tag)
            begin
                parent = load_issue(parent_tag)
            rescue
                parent_tag = nil
            end
            issue[:parent] = parent_tag
            commit_issue(tag, issue, 'Changed parent of issue')
        end
        
        server.mount_proc('/read-issue') do |req, res|
            parts = req.unparsed_uri.split('/')
            tag = parts[2]
            issue = load_issue(tag)
            res.body = issue.to_json()
        end
        
        server.mount_proc('/ag.json') do |req, res|
            all_issues = {}
            tags_by_parent = {}
            all_tags(false).sort.each do |tag|
                issue = load_issue(tag)
                all_issues[tag] = issue
                tags_by_parent[issue[:parent]] ||= []
                tags_by_parent[issue[:parent]] << tag
            end
            
            def walk_tree(parent, all_issues, tags_by_parent)
                return unless tags_by_parent[parent]
                items = []
                count = tags_by_parent[parent].size
                tags_by_parent[parent].sort do |a, b|
                    issue_a = all_issues[a]
                    issue_b = all_issues[b]
                    issue_a[:summary].downcase <=> issue_b[:summary].downcase
                end.each_with_index do |tag, index|
                    issue = all_issues[tag]
                    items << {'tag' => tag, 'summary' => issue[:summary]}
                    if tags_by_parent.include?(tag)
                        items.last['children'] = walk_tree(tag, all_issues, tags_by_parent)
                    end
                end
                return items
            end
            
            items = walk_tree(nil, all_issues, tags_by_parent)
            res.body = items.to_json()
        end        

        puts
        puts "Please go to >>> http://localhost:19816 <<< to interact with the issue tracker."
        puts
        
        fork do
            system("google-chrome http://localhost:19816")
        end
        
        server.start
    end
    
    def log()
        ag_branch = Rugged::Branch.lookup(@repo, '_ag')
        if ag_branch
            
            walker = Rugged::Walker.new(@repo)
            walker.push(ag_branch.target)
            max_author_width = 1
            walker.each do |commit|
                max_author_width = commit.author[:name].size if commit.author[:name].size > max_author_width
            end
            
            walker = Rugged::Walker.new(@repo)
            walker.push(ag_branch.target)
            walker.each do |commit|
                puts "#{commit.author[:time].strftime('%Y/%m/%d %H:%M:%S')} | #{sprintf('%-' + max_author_width.to_s + 's', commit.author[:name])} | #{commit.message}"
            end
        end
    end
    
    def help()
        puts "Ag - issue tracking intertwined with Git"
        puts
        puts "Usage: ag <command> [<args>]"
        puts
        puts "Available commands:"
        puts "   edit       Edit an issue"
        puts "   list       List all issues"
        puts "   new        Create a new issue"
        puts "   oneline    Describe an issue in a single line"
        puts "   reparent   Re-define the parent issue of an issue"
        puts "   rm         Remove an issue"
        puts "   show       Show detailed issue information"
        puts "   start      Start working on an issue"
        puts "   web        Interact with issues via web browser"
    end
end
