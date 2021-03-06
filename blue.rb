#!/usr/bin/env ruby
require 'cgi' # for HTML escaping

module Blue
  class TemplateLoader
    def initialize(search_path=[], suffix='.blue')
      @loaded_templates = {}
      @search_path = Array(search_path)
      @suffix = suffix
    end

    def get(name) # load if not loaded, otherwise return existing
      return @loaded_templates[name] if @loaded_templates[name]
      load_by_name(name)
    end

    def load_by_name(name) # load unconditionally
      @search_path.each{ |dir|
        filename = File.join(dir, name.to_s + @suffix)
        return load(filename) if File.exist?(filename)
      }
      nil
    end

    def load(filename) # load from file
      name = File.basename(filename)
      i = name.index('.')
      name = name[0..i-1] if i > 0
      instantiate(name, File.open(filename))
    end

    def loads(name, template) # load from string
      if template.is_a? String
        require 'stringio'
        template = StringIO.new(template)
      end
      instantiate(name, template)
    end

    def instantiate(name, body)
      template = Template.new(name, body, loader=self)
      @loaded_templates[name] = template.create
    end
  end

  class TemplateBase # base class for all generated templates
    def initialize()
      @filters = {
        :html => Proc.new { |text| CGI::escapeHTML(text) },
        :off => Proc.new { |x| x },
        :datefmt => Proc.new { |fmt| Proc.new { |d| d.strftime(fmt) } }
      }
      @filters.default_proc = proc do |hash, key|
        raise( "@filter: '#{key}' is not a valid filter name" )
      end
    end

    # def method_missing(method_name, *args, &block)
    #   return "SUBSTITUTED VALUE IS #{method_name}"
    # end
  end

  class Template
    def initialize(name, template, loader=nil, default_filter=:html)
      @name = name
      @template = template # template source
      @loader = loader
      @default_filter = default_filter
      @blocks = {
        'def' => {:method => method(:parse_def), :value => [], :process => method(:handle_body)},
        'block' => {:method => method(:parse_block), :value => [], :process => method(:handle_block)},
        'filter' => {:method => method(:parse_filter_command), :value => @default_filter},
        'extends' => {:method => method(:parse_extends), :value => Blue::TemplateBase},
        'include' => {:method => method(:parse_include)},
        'default' => {:method => method(:parse_default)},
      }

      # dollar regex
      # I used an idea from http://blog.stevenlevithan.com/archives/match-quoted-string for quoted strings
      # I didn't have this be strict on matching the opening quote with the same close quote because
      # this is only an approximation of correct syntax anyway and it made the regex simpler
        ident = /[A-Za-z]\w*/
       idents = /#{ident}(?:\.#{ident})*/
       string = /["'](?:\\?.)*?["']/
        value = /(?:#{string}|[\w:.]+?)/
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
      str.gsub(@dollar){ "${"+parse_filter($1,$2)+"}" }
    end

    def parse_filter(str, filter)
      filter.scan(@expr).map{ |exp|
        sym, paren = exp.split(/\b(?=\()/)
        [sym, paren ? ".call#{paren}" : '']
      }.reduce(str) { |v, f| "@filters.fetch(:#{f[0]})#{f[1]}.call(#{v})" }
      # ruby's error messages are awful here by default if a filter doesn't exist
      # "IndexError: key not found" - doesn't even mention what key is missing
    end

    def code_block?(item)
      item.instance_of? Array # I differentiate between text and code by wrapping code in an array
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
          if not in_str # string started
            in_str = chr
          elsif in_str == chr # string ending
            in_str = nil
          end
        end
      end

      raise 'PARSE ERROR' if not index

      (result << [str[startindex+2..index-1]]).concat(parse_braces(str[index+1..-1]))
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
        elsif line =~ /^\s*@(\S+)\s*(.+?)?\s*$/ # looks like "@foo params" (params optional)
          return text if $1 == 'end'
          output = false
          raise "Invalid @ block, unknown key '#{$1}' on template line #{@line_num}: '#{line}'" if not @blocks.key? $1
          # params to a block are the method name, the list of params,
          # a reference to the current lines, and a text block the method is allowed to modify
          @blocks[$1][:method].call($1, $2, lines, text)
        else
          # if the last line was output, or if the current line is blank, put a newline on the end of it
          text << '"\n"' if output or line.empty?
          next if line.empty?

          begin
            text.concat(parse_inline(line).map{ |item|
              code_block?(item) ? "@f.call((#{item[0]}).to_s)" : item.inspect
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
      out ||= Proc.new{ |item| "@b << #{item}" }
      body.map{ |item|
        code_block?(item) ? item[0] : out.call(item)
      }.join("\n") + "\n@b\n" # return @b at end
    end

    def handle_block(body)
      handle_body(body){ |item| "_b << #{item.inspect}" }
    end

    def create()
      begin
        klass = construct()
      rescue Exception => e
        raise "Error compiling template '#{@name}':\n\n#{e}\n\n"
      end

      begin
        return klass.new
      rescue Exception => e
        raise "Error instantiating template '#{@name}':\n\nError is: #{e}\n\n"
      end
    end

    def construct()
      # instance variables aren't available within Class.new since that class
      # has its own new set of instance variables. So, save everything you need
      # to locals so they're available within the define_method
      @line_num = 0
      _body = handle_body(handle_lines(@template))
      _extends = @blocks['extends'][:value]
      _filter = @default_filter

      # class blocks
      _code = @blocks.values.select{ |params|
        code_block?(params[:value]) and not params[:value].empty? and params[:process]
      }.map { |params|
        params[:value].map{ |item| params[:process].call(item) }
      }.join("\n")

      Class.new(_extends) do
        define_method(:render) do |*args|
          namespace = args[0] || {}
          return super(namespace) if _extends != Blue::TemplateBase
          @b = '' # buffer
          @f = @filters[:on] = @filters[:default] = @filters[_filter]
          _binding = binding
          _binding.eval namespace.keys.map { |k| "#{k} = namespace[#{k.inspect}]" }.join("\n")
          _binding.eval _body
        end
        eval _code

        define_method(:_source) do
          "def render()\n#{_body}\nend\n\n#{_code}"
        end
      end
    end

    def parse_def(type, params, lines, text)
      @blocks[type][:value] << ([["def #{params}"], *handle_lines(lines)] << ["''\nend"])
    end

    def parse_block(type, params, lines, text)
      # only output block on the first time it's defined
      text << ["#{params} binding"] unless @blocks['extends'][:value].instance_methods.index params
      @blocks[type][:value] << (
        [["def #{params}(b)\n_b=''"], *handle_body(handle_lines(lines))] << ["eval(_b, b)\nend"]
      )
    end

    def parse_filter_command(type, filter_name, lines, text)
      # params is the name of the filter you want to make default,
      # the string "off" to disable the default filter
      # or simply blank to re-enable the default filter
      text << ["@f = @filters[:#{filter_name ? filter_name : @blocks[type][:value]}]"]
    end

    def parse_extends(type, params, lines, text)
      raise "Parse error: @extends must appear on the first line of a template, and only one is allowed per template" if @line_num != 1
      raise "Must have a loader to use template inheritance" if not @loader
      @blocks[type][:value] = @loader.get(params.to_sym).class # get_extends_class(params) # check if there's a class with 'params' name
    end

    def parse_include(type, params, lines, text)
      raise "You must have specified a loader to use 'include'" if not @loader
      text << ["@b = 'INCLUDE NYI'"]
    end

    def parse_default(type, params, lines, text)
      # default looks like "default [], var[, var2, var3...]"
      # and results in assignments like var ||= []; var2 ||= [], etc.
      # this is naive and will fail if there's a comma character in your default
      # this is really only meant for setting a default "empty" value for
      # a variable used in your template if the caller doesn't provide it
      params = params.split(',').map{|s| s.strip}
      default = params.shift
      params.each{ |p|
        text << ["#{p} ||= #{default}"]
      }
    end
  end

  def self.template(*args)
    Blue::Template.new(*args).create
  end

  def self.render_template(template, data)
    # template is either a path or a template string directly
    # - treat it as a path if it's a one-line string
    # data is either the path to the data file (a string) or a hash to use directly
    if template.include? "\n" # template was passed as a string
      path = '<string>'
    else # template is the path to the template file
      path = File.expand_path template
      raise "Path '#{path}' not found" if !File.exist? path
      template = File.open(path)
    end

    template = self.template(path, template)

    if data.is_a? String
      data = File.expand_path data
      raise "Path '#{data}' not found" if !File.exist? data
      ext = File.extname(data)
      if ext == '.json'
        require 'json'
        data = JSON.load(File.open(data))
      elsif ext == '.yml' or ext == '.yaml'
        require 'yaml'
        data = YAML.load(File.open(data))
      end
    end

    template.render(data)
  end
end

if __FILE__ == $0
  # usage: blue template_path { data_path | arg=uments }
  template_path = ARGV.shift
  abort("Template path not provided") if not template_path
  abort("Template '#{template_path}' not found") if !File.file?(template_path)
  abort("Data not provided for template") if ARGV.length == 0
  data_path = ARGV[0]
  if File.file?(data_path)
    abort("Too many arguments") if ARGV.length > 1
    args = data_path
  else
    # modified from https://stackoverflow.com/a/26435303
    args = Hash[ ARGV.flat_map{|s| s.scan(/([^=\s]+)(?:=(\S+))?/)} ]
  end
  begin
    puts Blue::render_template(template_path, args)
  rescue NameError => e
    abort("Undefined template variable '#{e.name}'")
  end
end
