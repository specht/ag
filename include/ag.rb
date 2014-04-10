require 'date'
require 'highline/import'
require 'json'
require 'open3'
require 'rugged'
require 'set'
require 'tempfile'
require 'webrick'
require 'yaml'

require 'ag/cli-dispatcher'
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
            new_issue(ARGV[1, ARGV.size - 1])
        when 'show'
            show_object(ARGV[1])
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
        when 'cat'
            case ARGV[1]
            when 'list'
                list_categories()
            end
        end
    end
    
    def handle_auto_completion()
        parts = ENV['COMP_LINE'].split(' ')
        # append empty string if command line ends on space
        parts << '' if ENV['COMP_LINE'][-1] == ' '
        # consume program name
        parts.shift()
        
        AutoComplete::define(parts) do |ac|
            
            # all simple commands
            ['list', 'web', 'help', 'search', 'log'].each do |command|
                ac.option(command)
            end
            
            # 'new' requires zero, one, or more current category IDs
            ['new'].each do |command|
                ac.option(command, nil, true) do |ac|
                    all_category_ids(false).each do |id|
                        object = load_object(id)
                        ac.option(object[:slug])
                        ac.option(object[:slug], object[:slug])
                        object[:slug_pieces].each do |p|
                            ac.option(p, object[:slug])
                        end
                    end
                end
            end
            
            # all commands which require a current issue ID
            ['show', 'edit', 'start', 'oneline', 'rm'].each do |command|
                ac.option(command) do |ac|
                    all_ids(false).each do |id|
                        object = load_object(id)
                        ac.option(object[:slug])
                    end
                end
            end
            
            # special treatment for 'reparent' command
            ['reparent'].each do |command|
                ac.option(command) do |ac|
                    all_ids(false).each do |id|
                        object = load_object(id)
                        ac.option(object[:slug]) do |ac2|
                            all_ids(false).each do |id2|
                                object2 = load_object(id2)
                                ac2.option(object2[:slug])
                            end
                            ac2.option('null')
                        end
                    end
                end
            end
            
            # add cat commands
            ac.option('cat') do |ac2|
                ['list'].each do |command|
                    ac2.option(command)
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

    # return all IDs already assigned, with its most recent rev
    # if recursive == true, this includes IDs which have already
    # been removed (walks entire history of _ag branch, if present)
    # return all IDs if which == nil - it can also be 'categories' or 'issues'
    def all_ids_with_sha1(recursive = true, which = nil)
        ids = {}
        
        ag_branch = Rugged::Branch.lookup(@repo, '_ag')
        if ag_branch
            walker = Rugged::Walker.new(@repo)
            walker.push(ag_branch.target)
            walker.each do |commit|
                commit.tree.walk(:postorder) do |path, obj|
                    next unless obj[:type] == :blob
                    if which
                        next if path != which + '/'
                    end
                    id = obj[:name]
                    ids[id] ||= commit.oid
                end
                break unless recursive
            end
        end
        
        return ids
    end

    def all_ids(recursive = true, which = nil)
        ids = all_ids_with_sha1(recursive, which)
        return Set.new(ids.keys)
    end
    
    def all_category_ids(recursive = true)
        return all_ids(recursive, 'category')
    end

    def all_issue_ids(recursive = true)
        return all_ids(recursive, 'issue')
    end

    def gen_id()
        existing_ids = all_ids(true, nil)
        loop do
            result = ''
            2.times { result += (rand(26) + 'a'.ord).chr }
            4.times { result += (rand(10) + '0'.ord).chr }
            return result if !existing_ids.include?(result)
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

    def parse_object(s, id)
        id = id[0, 6]
        original = s.dup
        
        lines = s.split("\n")
        if lines[0].index('Summary:') != 0
            raise 'Missing summary field in object'
        end
        
        summary = lines[0].sub('Summary:', '').strip
        lines.delete_at(0)
        
        parent = nil
        if !lines.empty? && lines[0].index('Parent:') == 0
            parent = lines[0].sub('Parent:', '').strip
            parent = nil if parent == 'null'
            lines.delete_at(0)
        end
        
        categories = nil
        if !lines.empty? && lines[0].index('Categories:') == 0
            categories = lines[0].sub('Categories:', '').strip.split(' ').map do |x| 
                x.strip
                x = x[0, x.size - 1] if x[-1] == ','
                x.strip
            end.select do |x|
                !x.empty?
            end
            lines.delete_at(0)
        end
        
        description = lines.join("\n")
        description.strip!
        
        summary_pieces = summary.downcase.gsub(/[^a-z0-9]/, ' ').split(' ').select { |x| !x.strip.empty? }[0, 8]
        slug = "#{id}-#{summary_pieces.join('-')}"
        
        return {:id => id, :original => original, :parent => parent,
                :categories => categories, :summary => summary, 
                :description => description, :slug => slug, :slug_pieces => summary_pieces}
    end

    def load_object(id)
        id = id[0, 6]
        ag_branch = Rugged::Branch.lookup(@repo, '_ag')
        if ag_branch
            walker = Rugged::Walker.new(@repo)
            walker.push(ag_branch.target)
            walker.each do |commit|
                commit.tree.walk(:postorder) do |path, blob|
                    test_id = blob[:name]
                    if test_id == id
                        # found something!
                        object = parse_object(@repo.lookup(blob[:oid]).content, id)
                        object[:type] = path[0, path.size - 1]
                        unless ['issue', 'category'].include?(object[:type])
                            raise "Internal error."
                        end
                        return object
                    end
                end
            end
        end
        raise "No such object: [#{id}]."
    end
    
    def load_issue(id)
        object = load_object(id)
        if object[:type] != 'issue'
            raise "Expected an issue, got something else."
        end
        return object
    end
    
    def load_category(id)
        object = load_object(id)
        if object[:type] != 'category'
            raise "Expected a category, got something else."
        end
        return object
    end
    
    def find_commits_for_issues()
        results = {}
        walker = Rugged::Walker.new(@repo)
        walker.push(@repo.head.target)
        walker.each do |commit|
            message = commit.message
            if message =~ /^\[[a-z]{2}\d{4}\]/
                id = message[1, 6]
                results[id] ||= {
                    :count => 0,
                    :time_min => commit.time,
                    :time_max => commit.time,
                    :authors => Set.new()
                }
                results[id][:count] += 1
                results[id][:authors] << "#{commit.author[:name]} <#{commit.author[:email]}>"
                results[id][:time_min] = commit.time if commit.time < results[id][:time_min]
                results[id][:time_max] = commit.time if commit.time > results[id][:time_max]
            end
        end
        return results
    end

    def list_issues()
        commits_for_issues = find_commits_for_issues()
        all_issues = {}
        ids_by_parent = {}
        all_ids(false, 'issue').each do |id|
            issue = load_issue(id)
            all_issues[id] = issue
            ids_by_parent[issue[:parent]] ||= []
            ids_by_parent[issue[:parent]] << id
        end
        
        def print_tree(parent, all_issues, ids_by_parent, commits_for_issues, prefix = '')
            count = ids_by_parent[parent].size
            ids_by_parent[parent].sort do |a, b|
                    issue_a = all_issues[a]
                    issue_b = all_issues[b]
                    issue_a[:summary].downcase <=> issue_b[:summary].downcase
                end.each_with_index do |id, index|
                issue = all_issues[id]
                box_art = ''
                if parent
                    if index < count - 1
                        box_art = "\u251c\u2500\u2500"
                    else
                        box_art = "\u2514\u2500\u2500"
                    end
                end
                puts "[#{id}] #{commits_for_issues.include?(id) ? '*' : ' '} #{prefix}#{box_art}#{issue[:summary]}"
                if ids_by_parent.include?(id)
                    print_tree(id, all_issues, ids_by_parent, commits_for_issues, parent ? prefix + (index < count - 1 ? "\u2502  " : "   ") : prefix)
                end
            end
        end

        if ids_by_parent[nil]
            print_tree(nil, all_issues, ids_by_parent, commits_for_issues)
        end
    end

    def list_categories()
        commits_for_issues = find_commits_for_issues()
        all_categories = {}
        ids_by_parent = {}
        all_ids(false, 'category').each do |id|
            category = load_category(id)
            all_categories[id] = category
            ids_by_parent[category[:parent]] ||= []
            ids_by_parent[category[:parent]] << id
        end
        
        def print_tree(parent, all_categories, ids_by_parent, commits_for_issues, prefix = '')
            count = ids_by_parent[parent].size
            ids_by_parent[parent].sort do |a, b|
                    category_a = all_categories[a]
                    category_b = all_categories[b]
                    category_a[:summary].downcase <=> category_b[:summary].downcase
                end.each_with_index do |id, index|
                category = all_categories[id]
                box_art = ''
                if parent
                    if index < count - 1
                        box_art = "\u251c\u2500\u2500"
                    else
                        box_art = "\u2514\u2500\u2500"
                    end
                end
#                 puts "[#{id}] #{commits_for_issues.include?(id) ? '*' : ' '} #{prefix}#{box_art}#{issue[:summary]}"
                puts "[#{id}] #{prefix}#{box_art}#{category[:summary]}"
                if ids_by_parent.include?(id)
                    print_tree(id, all_categories, ids_by_parent, commits_for_issues, parent ? prefix + (index < count - 1 ? "\u2502  " : "   ") : prefix)
                end
            end
        end

        if ids_by_parent[nil]
            print_tree(nil, all_categories, ids_by_parent, commits_for_issues)
        end
    end

    def show_object(id)
        id = id[0, 6]
        object = load_object(id)
        ol = get_oneline(id)
        puts '-' * ol.size
        puts ol
        puts '-' * ol.size
        puts object[:original]
    end
    
    def get_oneline(id)
        id = id[0, 6]
        issue = load_object(id)
        parts = [issue[:summary]]
        p = issue
        while p[:parent]
            p = load_issue(p[:parent])
            parts.unshift(p[:summary])
        end
        return "[#{id}] #{parts.join(' / ')}"
    end
    
    def oneline(id)
        id = id[0, 6]
        puts get_oneline(id)
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
    def commit_issue(id, issue, comment, really_delete = false)
        id = id[0, 6]
        index = Rugged::Index.new
        begin
            @repo.rev_parse('_ag').tree.each_blob do |blob|
                unless blob[:name] == id
                    index.add(:path => 'categories/' + blob[:name], :oid => blob[:oid], :mode => blob[:filemode])
                end
            end
        rescue Rugged::ReferenceError => e
            # There's no _ag branch yet, but don't worry. It just means we don't
            # have any files to add yet
        end

        if issue
            oid = @repo.write(issue_to_s(issue), :blob)
            index.add(:path => 'categories/' + id, :oid => oid, :mode => 0100644)
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
            options[:message] ||= "#{comment} [#{id}]: #{issue[:summary]}"
        else
            options[:message] ||= "#{comment} [#{id}]"
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

    def new_issue(categories = [])
        linked_cats = Set.new()
        categories.each do |cat|
            cat = cat[0, 6]
            category = load_category(cat)
            linked_cats << cat
        end
        id = gen_id()
        
        template = "Summary: "
        unless linked_cats.empty?
            template += "\nCategories: #{linked_cats.map { |x| load_category(x)[:slug]}.to_a.sort.join(', ')}"
        end
        issue = parse_object(call_editor(template), id)
        
        if issue[:summary].empty?
            raise "Aborting due to empty summary."
        end
        
        puts issue.to_yaml
        
#         commit_issue(id, issue, "Added issue")
#         puts "Created new issue ##{id}: #{issue[:summary]}"
    end

    def edit_issue(id)
        id = id[0, 6]
        issue = load_issue(id)
        
        modified_issue = call_editor(issue[:original])
        if modified_issue != issue[:original]
            issue = parse_object(modified_issue, id)
            
            commit_issue(id, issue, 'Modified issue')
            puts "Modified issue ##{id}: #{issue[:summary]}"
        else
            puts "Leaving issue ##{id} unchanged: #{issue[:summary]}"
        end
    end
    
    def rm_issue(id)
        id = id[0, 6]
        issue = load_issue(id)
        
        puts "Removing issue: #{get_oneline(id)}"
    
        # If this issue has currently any children, we shouldn't remove it
        all_ids(false).each do |check_id|
            check_issue = load_issue(check_id)
            if check_issue[:parent] == id
                puts "Error: This issue has children, unable to continue."
                exit(1)
            end
        end
        
        response = ask("Are you sure you want to remove this issue [y/N]? ")
        if response.downcase == 'y'
            commit_issue(id, nil, 'Removed issue', true)
            puts "Removed issue ##{id}."
        else
            puts "Leaving issue ##{id} unchanged."
        end
    end
    
    def start_working_on_issue(id)
        id = id[0, 6]
        issue = load_issue(id)
        # if there's already a branch handling this issue, maybe don't create a new branch?
        system("git checkout -b #{issue[:slug]}")
    end
    
    def search(keywords)
        all_ids(true).each do |id|
            issue = load_issue(id)
            found_something = false
            keywords.each do |keyword|
                if issue[:original].downcase.include?(keyword.downcase)
                    puts get_oneline(id)
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
            id = parts[2]
            parent_id = parts[3]
            issue = load_issue(id)
            begin
                parent = load_issue(parent_id)
            rescue
                parent_id = nil
            end
            issue[:parent] = parent_id
            commit_issue(id, issue, 'Changed parent of issue')
        end
        
        server.mount_proc('/read-issue') do |req, res|
            parts = req.unparsed_uri.split('/')
            id = parts[2]
            issue = load_issue(id)
            res.body = issue.to_json()
        end
        
        server.mount_proc('/ag.json') do |req, res|
            all_issues = {}
            ids_by_parent = {}
            all_ids(false).sort.each do |id|
                issue = load_issue(id)
                all_issues[id] = issue
                ids_by_parent[issue[:parent]] ||= []
                ids_by_parent[issue[:parent]] << id
            end
            
            def walk_tree(parent, all_issues, ids_by_parent)
                return unless ids_by_parent[parent]
                items = []
                count = ids_by_parent[parent].size
                ids_by_parent[parent].sort do |a, b|
                    issue_a = all_issues[a]
                    issue_b = all_issues[b]
                    issue_a[:summary].downcase <=> issue_b[:summary].downcase
                end.each_with_index do |id, index|
                    issue = all_issues[id]
                    items << {'id' => id, 'summary' => issue[:summary]}
                    if ids_by_parent.include?(id)
                        items.last['children'] = walk_tree(id, all_issues, ids_by_parent)
                    end
                end
                return items
            end
            
            items = walk_tree(nil, all_issues, ids_by_parent)
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
        puts "Available category-related commands:"
        puts "   cat new       Create a new category"
        puts "   cat list      List all categories"
        puts "   cat show      Show raw category information"
        puts "   cat edit      Edit a new category"
        puts "   cat reparent  Re-define the parent category of a category"
        puts "   cat rm        Remove a category"
        puts
        puts "Available issue-related commands:"
        puts "   new           Create a new issue"
        puts "   list          List all issues"
        puts "   show          Show raw sissue information"
        puts "   edit          Edit an issue"
        puts "   link          Link an issue to a category"
        puts "   unlink        Unlink an issue from a category"
        puts "   start         Start working on an issue"
        puts "   rm            Remove an issue"
        puts
        puts "Miscellaneous commands:"
        puts "   web           Interact with Ag via web browser"
        puts "   help          Show usage information"
        puts
        puts "See 'ag help <command>' for more information on a specific command."
    end
end
