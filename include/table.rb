class Table
    def initialize()
        @headers = []
        @rows = []
    end
    
    def add_header(title)
        @headers << title
    end
    
    def add_row(row)
        @rows << row
    end
    
    def render()
        col_count = @rows.map { |x| x.size }.max
        col_widths = @rows.map { |x| x.map { |y| y.size } }.max
        
        # print headers
        (0...col_count).each do |oc|
            c = col_count - 1 - oc
            next unless @headers[c]
            label = @headers[c]
            size = col_widths[0, c].map { |x| x + 2 }.inject(0) { |x, y| x + y } + c + 1
            label = label[0, size - 2]
            label = ' ' * (size - label.size - 2) + '(' + label + ") \u2510" + ' ' * (col_widths[c] - 1)
            print(label)
            ((c + 1)...col_count).each do |d|
                print("   ")
                print("\u2502")
                print(' ' * (col_widths[d] - 1))
            end
            puts
        end
        
        # print header line
        print "\u250c"
        (0...col_count).each do |c|
            print("\u2500")
            print(@headers[c] ? "\u2534" : "\u2500")
            print("\u2500" * (col_widths[c]))
            print(c == (col_count - 1) ? "\u2510" : "\u252c")
        end
        puts
        
        # print rows
        @rows.each do |row|
            print("\u2502")
            (0...col_count).each do |c|
                cell = row[c]
                cell += ' ' * (col_widths[c] - cell.size)
                print(" #{cell} ")
                print("\u2502")
            end
            puts
        end

        # print footer line
        print "\u2514"
        (0...col_count).each do |c|
            print("\u2500" * (col_widths[c] + 2))
            print(c == (col_count - 1) ? "\u2518" : "\u2534")
        end
        puts
    end
end

__END__

                                       temp_int_ipa_barc
                                       temp_int_barc   │
     ra2767-add-optional-barcodes-to-consumables   │   │
───────────────────────────────────────────────┼─┬─┼─┬─┼─┬
f4410608 │ Mon Nov 17, 2014 │ Michael Specht ║ • │   │   │
