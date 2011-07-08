#Copyright (c) 2011, Keith Devens - http://keithdevens.com/
#Source code available at http://github.com/kbd/blue
#
#Permission is hereby granted, free of charge, to any person obtaining a copy of
#this software and associated documentation files (the "Software"), to deal in
#the Software without restriction, including without limitation the rights to
#use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
#the Software, and to permit persons to whom the Software is furnished to do so,
#subject to the following conditions:
#
#The above copyright notice and this permission notice shall be included in all
#copies or substantial portions of the Software.
#
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
#FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
#COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
#IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
#CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

module Blue
    class TemplateLoader
        def initialize(search_path=[], suffix='.blue')
            @loaded_templates = {}
            @search_path = search_path
            @suffix = suffix
        end
        
        def get(name, compiled=true)
            return @loaded_templates[name] if @loaded_templates[name]
            load_by_name(name, compiled)
        end
        
        def load_by_name(name, compiled=true)
            @search_path.each{ |dir|
                filename = File.join(dir, name.to_s + @suffix)
                return load(filename, compiled) if File.exist?(filename)
            }
            nil
        end
        
        def instantiate(name, body, compiled=true)
            template = Template.new(name, body, loader=self)
            if compiled
                @loaded_templates[name] = template.create
            else
                template.construct
            end
        end
        
        def load(filename, compiled=true) #load from file
            name = File.basename(filename)
            i = name.index('.')
            name = name[0..i-1] if i > 0
            instantiate(name, File.open(filename), compiled)
        end
        
        def loads(name, template, compiled=true) #load from string
            if template.is_a? String
                require 'stringio'
                template = StringIO.new(template)
            end
            instantiate(name, template, compiled)
        end
    end

    class TemplateBase #base class for all generated templates
        def initialize()
            @filters = {
                :html => Proc.new{ |text| require 'cgi'; CGI::escapeHTML(text) },
                :off => Proc.new { |x| x },
                :caps => Proc.new{ |x| x.capitalize },
                :datefmt => Proc.new{ |fmt| Proc.new{ |d| d.strftime(fmt) } }
            }
        end
    end
    
    class Template
        def classify_name(name)
            name.split(/\W+/).map(&:capitalize).join('')
        end
        
        def initialize(name, template, loader=nil, default_filter=:html)
            @name = classify_name(name) + "Template" #name must be a valid Ruby class name
            @template = template #template source
            @loader = loader
            @default_filter = default_filter
            @blocks = {
                'def' => {:method => method(:parse_def), :value => [], :process => method(:handle_body)},
                'block' => {:method => method(:parse_block), :value => [], :process => method(:handle_block)},
                'filter' => {:method => method(:parse_filter_command), :value => @default_filter},
                'extends' => {:method => method(:parse_extends), :value => Blue::TemplateBase},
                'include' => {:method => method(:parse_include), :value => nil},
                'placeholders' => {:method => method(:parse_placeholders), :value => []}
            }
            
            #dollar regex
              ident = /[A-Za-z]\w*/
             idents = /#{ident}(?:\.#{ident})*/
             string = /["\'](?:\\?.)*?["\']/
              value = /(?:#{string}|[\w.]+?)/
               brac = /(?:\((?:#{value},?)*\)|\[#{value}?\])/
                var = /#{idents}#{brac}*/
              @expr = /#{var}(?:\.#{var})*/
             filter = /(?:\|#{@expr})*/
            @dollar = /\$(#{@expr})(#{filter})/
        end
        
        def parse_inline(line)
            parse_braces(parse_dollar(line))
        end
    
        def parse_dollar(str)
            #used an idea from http://blog.stevenlevithan.com/archives/match-quoted-string for quoted strings
            #I didn't have this be strict on matching the opening quote with the same close quote because
            #this is only an approximation of correct syntax anyway and it made the regex simpler
            #               
            str.gsub(@dollar){ "${"+parse_filter($1,$2)+"}" }
        end
    
        def parse_filter(str, filter)
            filter.scan(@expr).map{ |exp|
                sym, paren = exp.split(/\b(?=\()/)
                [sym, paren ? ".call#{paren}" : '']
            }.reduce(str) { |v, f| "@filters.fetch(:#{f[0]})#{f[1]}.call(#{v})" }
            #ruby's error messages are freaking awful here by default if a filter doesn't exist
            #"IndexError: key not found" - doesn't even mention what key is missing
        end
        
        def code_block?(item)
            item.instance_of? Array #I differentiate between text and code by wrapping code in an array
        end
    
        def parse_braces(str)
            return [] if str.empty?
            return [str] if not (startindex = str.index('${'))
            result = (startindex > 0 ? [str[0..startindex-1]] : [])
            
            in_str = nil
            brace_count = 0
            in_escape = false
            index = startindex+1
    
            # the only characters that are relevant are ", ', {, }, \
            while index = str.index(/["'{}\\]/, index+1) do
                if in_escape
                    in_escape = false
                    next
                end
                
                case chr = str[index].chr
                when '\\' then in_escape = true
                when '{' then brace_count += 1 if not in_str
                when '}' then break if not in_str and (brace_count -= 1) < 0
                when '"', "'"
                    if not in_str #string started
                        in_str = chr 
                    elsif in_str == chr #string ending
                        in_str = nil
                    end
                end
            end
            
            raise 'PARSE ERROR' if not index
    
            (result << [[str[startindex+2..index-1]]]).concat(parse_braces(str[index+1..-1]))
        end
        
        def handle_lines(lines)
            text = []
            output = false
            lines.each_line do |line|
                @line_num += 1
                line.chomp!
                if line.lstrip.start_with? '%'
                    output = false
                    text << [line.lstrip[1..-1]]
                elsif line =~ /^\s*@(\S+)(?:\s+(.*?)\s*)?$/ #looks like "@foo params" (params optional)
                    return text if $1 == 'end'
                    output = false
                    raise "Invalid @ block, unknown key '#{$1}' on template line #{@line_num}: '#{line}'" if not @blocks.key? $1
                    @blocks[$1][:method].call($1, $2, lines, text)
                else
                    #if the last line was output, or if the current line is blank, put a newline on the end of it
                    text << '"\n"' if output or line.empty?
                    next if line.empty?
                    
                    begin
                        text.concat(parse_inline(line).map{ |item|
                            code_block?(item) ? "@filter.call((#{item[0]}).to_s)" : item.inspect
                        })
                    rescue => e
                        raise "Error parsing at template line #{@line_num}: '#{line}' - #{e}"
                    end
                    output = true
                end
            end
            text
        end
        
        def handle_body(body, &out)
            out ||= Proc.new{ |item| "@buffer << #{item}" }
            body.map{ |item|
                code_block?(item) ? item[0] : out.call(item)
            }.join("\n") + "\n"
        end
        
        def handle_block(body)
            handle_body(body){ |item| "_buffer << #{item.inspect}" }
        end

        def create()
            begin
                eval(construct())
            rescue Exception => e
                raise "Error compiling template #{@name}:\n\n#{e}\n\n"
            end
            
            begin
                return eval(@name).new
            rescue Exception => e
                raise "Error instantiating template #{@name}:\n\nError is: #{e}\n\n"
            end
        end
    
        def construct()
            @line_num = 0
            @head = ''
            body = handle_body(handle_lines(@template))
            cls = <<END_OF_CODE
    class #{@name} < #{@blocks['extends'][:value]}
        def render(namespace={}, _filter=#{@default_filter.inspect})
END_OF_CODE
        if @blocks['extends'][:value] != Blue::TemplateBase
            cls << "#{@head}\nsuper\nend\n"
        else
            cls << @head << <<'END_OF_CODE'
            @filter = @filters[_filter]
            @buffer = ''
            eval namespace.keys.map { |k| "#{k} = namespace[#{k.inspect}]" }.join("\n")
END_OF_CODE
            #have to eval the code in a heredoc instead of just executing the code directly
            # because you can't otherwise access the namespace variables created through an eval
            # http://keithdevens.com/weblog/archive/2011/May/23/eval.locals
            cls << <<END_OF_CODE
            eval <<'THIS_STRING_BETTER_NOT_APPEAR_IN_THE_TEMPLATE'
#{body}
THIS_STRING_BETTER_NOT_APPEAR_IN_THE_TEMPLATE
        end
END_OF_CODE
        end
            #output all class blocks
            @blocks.each{ |type, params|
                next if not code_block?(params[:value]) or params[:value].empty? or not params[:process]
                params[:value].each{ |item|
                    cls << params[:process].call(item)
                }
            }
            
            cls << "end\n"
        end
        
        def parse_def(type, params, lines, text)
            @blocks[type][:value] << ([["def #{params}"], *handle_lines(lines)] << ["''\nend"])
        end

        def parse_block(type, params, lines, text)
            text << ["#{params} binding"] unless @blocks['extends'][:value].instance_methods.index params #only output block on the first time it's defined
            @blocks[type][:value] << ([["def #{params}(b)\n_buffer=''"], *handle_body(handle_lines(lines))] << ["eval(_buffer, b)\nend"])
        end
        
        def parse_filter_command(type, filter_name, lines, text)
            #params is the name of the filter you want to make default,
            # the string "off" to disable the default filter
            # or simply blank to re-enable the default filter
            text << ["@filter = @filters[:#{filter_name ? filter_name: @blocks[type][:value]}]"]
        end
        
        def parse_extends(type, params, lines, text)
            raise "Parse error: @extends must appear on the first line of a template, and only one is allowed per template" if @line_num != 1
            raise "Must have a loader to use template inheritance" if not @loader
            @blocks[type][:value] = @loader.get(params.to_sym).class #get_extends_class(params) #check if there's a class with 'params' name
        end
        
        def parse_include(type, params, lines, text)
            raise "You must have specified a loader to use 'include'" if not @loader 
            text << ["@buffer = 'INCLUDE NYI'"]
        end
        
        def parse_placeholders(type, params, lines, text)
            @head << params.split.join('=') << " = ''\n"
        end
    end
end