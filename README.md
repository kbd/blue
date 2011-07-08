Blue
====

Blue is a minimal in design, but full-featured template language for Ruby.

Features
--------

* template inheritance (the only template language in Ruby I'm aware of that does)
* blocks
* filters
* functions
* super convenient variable substitution
* has a loader that caches pre-generated templates
   
Currently version 0.9. It's nearly fully functional and seems stable but it
still needs a few small features, needs to be battle tested more, and I need to
learn how to make it a gem. Other todos before release include Tilt support, a
nice interface for Sinatra, and partials/includes.

Also, I'm pretty new to Ruby so please feel free to offer style suggestions.

Basic Usage
-----------

    require 'blue'
    loader = Blue::TemplateLoader.new './templates'
    namespace = {:entries => Weblog.entries, :breadcrumbs => breadcrumbs}
    loader.get(:weblog).render(namespace)
    
Template Language
-----------------

There are only a few constructs. Here's an example template, I'll include more
documentation later.

    @extends base
    
    @block content
    
    % prevday = nil
    % entries.each do |entry|
        % day = entry.creation_dt.strftime('%B %d, %Y')
        % if day != prevday
            <h2>
                <a title="permanent link for $day" href="$entry.dateuri">$entry.creation_dt|datefmt('%A, %B %d, %Y')</a>
            </h2>
        %end
        <h3><a href="$entry.url">$entry.title</a></h3>
        
        $printEntry(entry)
        % prevday = day
    % end
    
    <p>There were ${entries.length} entries, and you can print a dollar sign like ${'$'}.
    Though of course a dollar sign won't be misinterpreted if it appears by itself $ or
    as part of something that doesn't look like a variable reference (i.e. like money $3.50)</p>
    @end
    
    @def printEntry(entry)
    	<div id="id$entry.id">
            <h3><a href="$entry.permalink">$entry.title</a></h3>
            @filter off
            $entry.rawhtml
            @filter
        </div>
	@end
    
As you can see, a line starting with '%' just escapes out to Ruby code, and
anything in a ${...} is a Ruby expression. Variable substitution is done by
starting something that looks like a variable reference or function call with a
dollar sign. Blue tries to be somewhat smart about what "looks like" a variable
substitution but it's not foolproof. You can define functions, use filters,
template inheritance, and so on.

License
-------

MIT licensed