require 'set'

class AutoCompleteHelper
    def initialize()
        # keys: :block, :values: :has_values, :inception
        @options = {}
        @handler = nil
    end
    
    def option(name, value = nil, inception = false, &block)
        @options[name] ||= {}
        @options[name][:block] ||= block
        @options[name][:values] ||= Set.new()
        @options[name][:values] << (value ? value : name)
        @options[name][:has_values] ||= false
        @options[name][:has_values] = true if value
        @options[name][:inception] = inception
    end
    
    def handler(&block)
        @handler = block
    end
    
    def options()
        return @options
    end
    
    def get_handler()
        return @handler
    end
end

class CliDispatcher
#     File::open('log.txt', 'a+') do |f|
#         f.puts '-' * 50
#     end
#     
#     def self.log(s)
#         File::open('log.txt', 'a+') do |f|
#             f.puts s
#         end
#     end
    
    @@completion_mode = ENV['COMP_LINE'] != nil
    
    def self.launch(parts = nil, parent_inception = false, collected_parts = [], &block)
        unless parts
            parts = ARGV.dup
            if @@completion_mode
                parts = ENV['COMP_LINE'].split(' ')
                # append empty string if command line ends on space
                parts << '' if ENV['COMP_LINE'][-1] == ' '
                # consume program name
                parts.shift()
            end
        end
        
        # call the block and populate choices
        ac = AutoCompleteHelper.new
        yield(ac, collected_parts)

        # if we're not in completion mode and a handler is defined, call it
        if (!@@completion_mode) && ac.get_handler()
            ac.get_handler().call(parts)
            # terminate because otherwise, we'll call this handler multiple 
            # times for 'inception' options
            exit(0)
        end
        choices = ac.options.keys.sort
        
        part = parts.shift()
        part ||= ''
        part = part.downcase
        collected_parts << part
        
        choices.select! do |x| 
            # for options with value, it's enough if the part is somewhere in the value
            if ac.options[x][:has_values]
                x.include?(part)
            else
                x[0, part.size] == part
            end
        end
        choice_values = choices.inject(Set.new()) do |s, choice|
            s | ac.options[choice][:values]
        end
#         log("We encountered a part (#{part}), remaining parts are: [#{parts.join(', ')}], remaining choices are: [#{choices.to_a.sort.join(', ')}] => [#{choice_values.to_a.sort.join(', ')}]")
        
        if @@completion_mode && parts.empty?
            # there are no more parts to process
            if choices.include?(part)
                choice_values.each do |value|
                    puts value
                end
                exit(0)
            else
                choice_values.each do |value|
                    puts value
                end
                exit(0)
            end
        end
        
        # there are more parts to process
        # the current part is one of our choices, recurse
        if choices.include?(part)
            # fetch next block, unless we're in... INCEPTION MODE!!! *thunderclap*
            block = ac.options[choices.first][:block] unless parent_inception
            if block
                self.launch(parts, parent_inception || ac.options[choices.first][:inception], 
                            collected_parts, &block)
            else
                exit(0)
            end
        else
            if @@completion_mode
                choice_values.each do |value|
                    puts value
                end
                exit(0)
            end
        end
    end
    
    def self.define(parts, parent_inception = false, &block)
        # call the block and populate choices
        ac = AutoCompleteHelper.new
        yield(ac)
        choices = ac.options.keys.sort
        
        part = parts.shift()
        part ||= ''
        
        choices.select! do |x| 
            # for options with value, it's enough if the part is somewhere in the value
            if ac.options[x][:has_values]
                x.include?(part)
            else
                x[0, part.size] == part
            end
        end
        choice_values = choices.inject(Set.new()) do |s, choice|
            s | ac.options[choice][:values]
        end
#         log("We encountered a part (#{part}), remaining parts are: [#{parts.join(', ')}], remaining choices are: [#{choices.to_a.sort.join(', ')}] => [#{choice_values.to_a.sort.join(', ')}]")
        
        if parts.empty?
            # there are no more parts to process
            if choices.include?(part)
                choice_values.each do |value|
                    puts value
                end
                exit(0)
            else
                choice_values.each do |value|
                    puts value
                end
                exit(0)
            end
        else
            # there are more parts to process
            # the current part is one of our choices, recurse
            if choices.include?(part)
                # fetch next block, unless we're in INCEPTION MODE!!! *thunderclap*
                block = ac.options[choices.first][:block] unless parent_inception
                if block
                    self.define(parts, parent_inception || ac.options[choices.first][:inception], &block)
                else
                    exit(0)
                end
            else
                choice_values.each do |value|
                    puts value
                end
                exit(0)
            end
        end
    end
end
