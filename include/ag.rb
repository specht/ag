require 'date'
require 'json'
require 'rugged'
require 'set'
require 'tempfile'
require 'webrick'
require 'yaml'

require 'ag/autocomplete'

class Ag
    
    def initialize()
        srand()
        
        @config = Rugged::Config.global.to_hash
        
        @editor = 'nano'
        @editor = ENV['EDITOR'] if ENV['EDITOR']
        
        begin
            @repo = Rugged::Repository.new(Rugged::Repository.discover(Dir::pwd()))
        rescue Rugged::RepositoryError => e
            puts e
            exit(1)
        end
        
        handle_auto_completion() if ENV.include?('COMP_LINE')
        
        ensure_git_hook_present()
        
        case ARGV[0]
        when 'list'
            list_issues()
        when 'show'
            show_issue(ARGV[1])
        when 'edit'
            edit_issue(ARGV[1])
        when 'new'
            new_issue(ARGV[1])
        when 'start'
            start_working_on_issue(ARGV[1])
        when 'oneline'
            oneline(ARGV[1])
        when 'web'
            web()
        end
    end
    
    def handle_auto_completion()
        parts = ENV['COMP_LINE'].split(' ')
        parts.shift()
        AutoComplete::define(parts) do |ac|
            
            # all simple commands
            ['list', 'web'].each do |command|
                ac.option(command)
            end
            
            # all commands which require an issue ID
            ['new', 'show', 'edit', 'start', 'oneline'].each do |command|
                ac.option(command) do |ac|
                    all_tags.each do |tag|
                        ac.option(tag)
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
    
    def all_tags()
        tags = Set.new()
        begin
            @repo.rev_parse('_ag').tree.each_blob do |blob|
                tag = blob[:name]
                tags << tag
            end
        rescue Rugged::ReferenceError => e
            # _ag branch is not there yet, return no tags, but that's ok
        end
        return tags
    end

    def gen_tag()
        existing_tags = all_tags()
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
            File::open(file.path, 'w') do |f|
                f.write(template)
            end
            system("#{@editor} #{file.path}")
            contents = File.read(file.path)
        ensure
            file.close
            file.unlink
        end
        return contents
    end

    def parse_issue(s, tag)
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
        
        return {:tag => tag, :original => original, :parent => parent,
                :summary => summary, :description => description}
    end

    def load_issue(tag)
        @repo.rev_parse('_ag').tree.each_blob do |blob|
            test_tag = blob[:name]
            if test_tag == tag
                issue = parse_issue(@repo.lookup(blob[:oid]).content, tag)
                return issue
            end
        end
        raise "No such issue: [#{tag}]."
    end
    
    def find_commits_for_issues()
        results = {}
        walker = Rugged::Walker.new(@repo)
#         walker.sorting(Rugged::SORT_TOPO | Rugged::SORT_REVERSE)
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
#         commits_for_issues = find_commits_for_issues()
#         puts commits_for_issues.to_yaml
        all_issues = {}
        tags_by_parent = {}
        all_tags.sort.each do |tag|
            issue = load_issue(tag)
            all_issues[tag] = issue
            tags_by_parent[issue[:parent]] ||= []
            tags_by_parent[issue[:parent]] << tag
        end
        
        def print_tree(parent, all_issues, tags_by_parent, prefix = '')
            count = tags_by_parent[parent].size
            tags_by_parent[parent].sort.each_with_index do |tag, index|
                issue = all_issues[tag]
                box_art = ''
                if parent
                    if index < count - 1
                        box_art = "\u251c\u2500\u2500"
                    else
                        box_art = "\u2514\u2500\u2500"
                    end
                end
                puts "[#{tag}] #{prefix}#{box_art}#{issue[:summary]}"
                if tags_by_parent.include?(tag)
                    print_tree(tag, all_issues, tags_by_parent, parent ? prefix + "\u2502  " : prefix)
                end
            end
        end
        
        print_tree(nil, all_issues, tags_by_parent)
    end

    def show_issue(tag)
        issue = load_issue(tag)
        puts issue[:original]
    end
    
    def oneline(tag)
        issue = load_issue(tag)
        parts = [issue[:summary]]
        p = issue
        while p[:parent]
            p = load_issue(p[:parent])
            parts.unshift(p[:summary])
        end
        puts "[#{tag}] #{parts.join(' / ')}"
    end
    
    def issue_to_s(issue)
        result = ''
        
        result += "Summary: #{issue[:summary]}\n"
        result += "Parent: #{issue[:parent]}\n" if issue[:parent]
        result += "\n"
        result += issue[:description]
        
        return result
    end
    
    def commit_issue(tag, issue, comment)
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

        oid = @repo.write(issue_to_s(issue), :blob)
        index.add(:path => tag, :oid => oid, :mode => 0100644)

        options = {}
        options[:tree] = index.write_tree(@repo)

        options[:author] = { :email => @config['user.email'], :name => @config['user.name'], :time => Time.now }
        options[:committer] = { :email => @config['user.email'], :name => @config['user.name'], :time => Time.now }
        options[:message] ||= "#{comment} [#{tag}]: #{issue[:summary]}"
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
        issue = load_issue(tag)
        
        issue = parse_issue(call_editor(issue[:original]), tag)
        
        commit_issue(tag, issue, 'Modified issue')
        puts "Modified issue ##{tag}: #{issue[:summary]}"
    end
    
    def start_working_on_issue(tag)
        issue = load_issue(tag)
        summary_pieces = issue[:summary].downcase.gsub(/[^a-z0-9]/, ' ').split(' ').select { |x| !x.empty? }[0, 8]
        slug = "#{issue[:tag]}-#{summary_pieces.join('-')}"
        # if there's already a branch handling this issue, maybe don't create a new branch?
        system("git checkout -b #{slug}")
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
            rescue Rugged::ReferenceError => e
                parent_tag = nil
            end
            issue[:parent] = parent_tag
            commit_issue(tag, issue, 'Changed parent of issue')
        end
        
        server.mount_proc('/ag.json') do |req, res|
            all_issues = {}
            tags_by_parent = {}
            all_tags.sort.each do |tag|
                issue = load_issue(tag)
                all_issues[tag] = issue
                tags_by_parent[issue[:parent]] ||= []
                tags_by_parent[issue[:parent]] << tag
            end
            
            def walk_tree(parent, all_issues, tags_by_parent)
                items = []
                count = tags_by_parent[parent].size
                tags_by_parent[parent].sort.each_with_index do |tag, index|
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
        server.start
    end
end
