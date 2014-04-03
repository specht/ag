class AutoCompleteHelper
    def initialize()
        @options = {}
    end
    
    def option(name, &block)
        @options[name] = block
    end
    
    def options()
        return @options
    end
end

class AutoComplete
    def self.define(parts, &block)
        ac = AutoCompleteHelper.new
        yield(ac)
        choices = ac.options.keys.sort
        if parts.first
            choices.select! { |x| x[0, parts.first.size] == parts.first }
        end
        if choices.size == 1 && choices.first == parts.first
            parts.delete_at(0)
            block = ac.options[choices.first]
            if block
                self.define(parts, &block)
            else
                exit(0)
            end
        else
            puts choices.join("\n")
            exit(0)
        end
    end
end
