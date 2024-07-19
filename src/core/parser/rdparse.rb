#!/usr/bin/env ruby

# This file is called rdparse.rb because it implements a Recursive
# Descent Parser. Read more about the theory on e.g.
# http://en.wikipedia.org/wiki/Recursive_descent_parser

# 2010-02-11 New version of this file for the 2010 instance of TDP007
#   which handles false return values during parsing, and has an easy way
#   of turning on and off debug messages.
# 2014-02-16 New version that handles { false } blocks and :empty tokens.

require_relative '../error/cmdl_errors'

require 'logger'

class Rule

    attr_reader :logger

    Match = Struct.new :pattern, :block

    def initialize(name, parser)
        @logger = parser.logger
        # The name of the expressions this rule matches
        @name = name
        # We need the parser to recursively parse sub-expressions occurring 
        # within the pattern of the match objects associated with this rule
        @parser = parser
        @matches = []
        # Left-recursive matches
        @lrmatches = []
    end

    # Add a matching expression to this rule, as in this example:
    #   match(:term, '*', :dice) {|a, _, b| a * b }
    # The arguments to 'match' describe the constituents of this expression.
    def match(*pattern, &block)
        match = Match.new(pattern, block)
        # @logger.inf  "Rule '#{@name}' created match pattern: #{pattern}"
        # If the pattern is left-recursive, then add it to the left-recursive set
        if pattern[0] == @name
            pattern.shift
            @lrmatches << match
        else
            @matches << match
        end
    end

    def parse
        # @logger.info("Parsing rule '#{@name}'")
        # Try non-left-recursive matches first, to avoid infinite recursion
        match_result = try_matches(@matches)
        return nil if match_result.nil?
        loop do
            result = try_matches(@lrmatches, match_result)
            return match_result if result.nil?
            match_result = result
        end
    end

    private

    # Try out all matching patterns of this rule
    def try_matches(matches, pre_result = nil)
        match_result = nil
        # Begin at the current position in the input string of the parser
        start = @parser.pos

        # @logger.debug "Trying matches, starting at position #{start}"

        matches.each do |match|
            # @logger.info("Trying to match pattern '#{match.pattern.inspect}'")
            # pre_result is a previously available result from evaluating expressions
            result = pre_result.nil? ? [] : [pre_result]

            # We iterate through the parts of the pattern, which may be e.g.
            #   [:expr,'*',:term]
            match.pattern.each_with_index do |token,index|

                # @logger.info("Trying to match token '#{token}'")

                # If this "token" is a compound term, add the result of
                # parsing it to the "result" array
                if @parser.rules[token]

                    # @logger.info "Compound term '#{token}' found, recursing..."

                    result << @parser.rules[token].parse
                    if result.last.nil?
                        result = nil
                        break
                    end

                    # @logger.info("Matched '#{@name} = #{match.pattern[index..-1].inspect}'")
                else
                    # Otherwise, we consume the token as part of applying this rule
                    next_token = @parser.expect(token)
                    # @logger.info("Next token: #{next_token.inspect}, position: #{@parser.pos}")

                    if next_token
                        result << next_token
                        if @lrmatches.include?(match.pattern) then
                            pattern = [@name]+match.pattern
                        else
                            pattern = match.pattern
                        end
                        @logger.debug("Matched token '#{next_token}' as part of rule '#{@name} <= #{pattern.inspect}'")
                    else
                        result = nil
                        break
                    end
                end # pattern.each
            end # matches.each

            if result
                if match.block
                    match_result = match.block.call(*result)
                else
                    match_result = result[0]
                end

                @logger.debug("'#{@parser.tokens[start..@parser.pos-1]}' matched '#{@name}' and generated '#{match_result.inspect}'") unless match_result.nil?
                break
            else
                # If this rule did not match the current token list, move
                # back to the scan position of the last match
                # @logger.debug("Match failed, moving back to position #{start}")
                @parser.pos = start
            end
        end

        return match_result
    end
end

class Parser
    attr_accessor :pos, :logger
    attr_reader :rules, :string, :tokens

    def initialize(language_name, log_level = Logger::DEBUG, &block)
        @logger = Logger.new($stdout)
        @logger.level = log_level
        @lex_tokens = []
        @rules = {}
        @start = nil
        @language_name = language_name
        instance_eval(&block)
    end

    def set_log_level(level)
        @logger.level = level
        @rules.each_value do |rule|
            rule.logger.level = level
        end
    end

    # Tokenize the string into small pieces
    def tokenize(string)
        @tokens = []
        @string = string.clone
        until string.empty?
            # Unless any of the valid tokens of our language are the prefix of
            # 'string', we fail with an exception
            raise ParseError, 
                "unable to lex '#{string}" unless @lex_tokens.any? do |tok|
                match = tok.pattern.match(string)
                # The regular expression of a token has matched the beginning of 'string'
                if match
                    # Also, evaluate this expression by using the block
                    # associated with the token
                    if tok.block
                        evaluated = tok.block.call(match.to_s)
                        @tokens << evaluated
                    end
                    @logger.debug("Token consumed: #{match[0]}")

                    # consume the match and proceed with the rest of the string
                    string = match.post_match
                    true
                else
                    # this token pattern did not match, try the next
                    false
                end # if
            end # raise
        end # until
    end

    def parse(string)
        # First, split the string according to the "token" instructions given.
        # Afterwards @tokens contains all tokens that are to be parsed. 
        tokenize(string)

        # @logger.info "Beginning parsing, rules: #{@rules.keys}"

        # These variables are used to match if the total number of tokens
        # are consumed by the parser
        @pos = 0
        @max_pos = 0
        @expected = []
        # Parse (and evaluate) the tokens received
        result = @start.parse
        # If there are unparsed extra tokens, signal error
        if @pos != @tokens.size
        raise ParseError,
                "Parse error. expected: '#{@expected.join(', ')}', found '#{@tokens[@max_pos]}'"
        end
        return result
    end

    def next_token
        @pos += 1
        return @tokens[@pos - 1]
    end

    # Return the next token in the queue
    def expect(tok)
        return tok if tok == :empty
        t = next_token
        if @pos - 1 > @max_pos
            @max_pos = @pos - 1
            @expected = []
        end
        return t if tok === t
        @expected << tok if @max_pos == @pos - 1 && !@expected.include?(tok)
        return nil
    end

    def to_s
        "Parser for #{@language_name}"
    end

    private

    LexToken = Struct.new(:pattern, :block)

    def token(pattern, &block)
        @lex_tokens << LexToken.new(Regexp.new('\\A' + pattern.source), block)
        # @logger.info("Added token pattern: #{pattern.source}")
    end

    def start(name, &block)
        rule(name, &block)
        @start = @rules[name]
        # @logger.info("Start rule is '#{name}'")
    end

    def rule(name,&block)
        @current_rule = Rule.new(name, self)
        @rules[name] = @current_rule
        # @logger.info("Created rule '#{name}'")
        instance_eval &block # In practise, calls match 1..N times
        @current_rule = nil
    end

    def match(*pattern, &block)
        # Basically calls memberfunction "match(*pattern, &block)
        @current_rule.send(:match, *pattern, &block)
    end

end
