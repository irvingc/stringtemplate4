/*
 [The "BSD licence"]
 Copyright (c) 2009 Terence Parr
 All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions
 are met:
 1. Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.
 2. Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.
 3. The name of the author may not be used to endorse or promote products
    derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
 IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
 INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

/** Recognize a single StringTemplate template text, expressions, and conditionals */
parser grammar STParser;

options {
	tokenVocab=MyLexer;
}

/*
tokens {
	IF='if('; ELSE='else'; ELSEIF='elseif('; ENDIF='endif'; SUPER='super.';
	SEMI=';'; BANG='!'; ELLIPSIS='...'; EQUALS='='; COLON=':';
	LPAREN='('; RPAREN=')'; LBRACK='['; RBRACK=']'; COMMA=','; DOT='.';
	LCURLY='{'; RCURLY='}'; PIPE='|';
	TEXT; LDELIM; RDELIM;
}
*/

@header { package org.stringtemplate; }

@members {
CodeGenerator gen;
public STParser(TokenStream input, CodeGenerator gen)
{
    this(input, new RecognizerSharedState());
    this.gen = gen;
}

protected Object recoverFromMismatchedToken(IntStream input, int ttype, BitSet follow)
	throws RecognitionException
{
	throw new MismatchedTokenException(ttype, input);
}

    public void refAttr(Token id) {
        String name = id.getText();
        if ( Interpreter.predefinedAttributes.contains(name) ) {
            gen.emit(Bytecode.INSTR_LOAD_LOCAL, name);
        }
        else {
            gen.emit(Bytecode.INSTR_LOAD_ATTR, name);
        }
    }

    public void setOption(Token id) {
        Integer I = Compiler.supportedOptions.get(id.getText());
        if ( I==null ) {
            System.err.println("no such option: "+id.getText());
            return;
        }
        gen.emit(Bytecode.INSTR_STORE_OPTION, I);
    }

    public void defaultOption(Token id) {
        String v = Compiler.defaultOptionValues.get(id.getText());
        if ( v==null ) {
            System.err.println("no def value for "+id.getText());
            return;
        }
        gen.emit(Bytecode.INSTR_LOAD_STR, v);
    }
    
    public void func(Token id) {
        Short funcBytecode = Compiler.funcs.get(id.getText());
        if ( funcBytecode==null ) {
            System.err.println("no such fun: "+id);
            gen.emit(Bytecode.INSTR_NOOP);
        }
        else {
            gen.emit(funcBytecode);
        }
    }
}

@rulecatch {
   catch (RecognitionException re) { throw re; }
}

templateAndEOF
	:	template EOF
	;

template
	:	(	TEXT
			{
			gen.emit(Bytecode.INSTR_LOAD_STR, $TEXT.getText());
			gen.emit(Bytecode.INSTR_WRITE);
			}
		|	conditional
		|	LDELIM expr
			(	';' exprOptions {gen.emit(Bytecode.INSTR_WRITE_OPT);}
			|	                {gen.emit(Bytecode.INSTR_WRITE);}
			)
			RDELIM
		)*
	;

conditional
@init {
    /** Tracks address of branch operand (in code block).  It's how
     *  we backpatch forward references when generating code for IFs.
     */
    int prevBranchOperand = -1;
    /** Branch instruction operands that are forward refs to end of IF.
     *  We need to update them once we see the endif.
     */
    List<Integer> endRefs = new ArrayList<Integer>();
}
	:	LDELIM i='if' '(' not='!'? {;} primary ')' RDELIM
		{
        prevBranchOperand = gen.address()+1;
        short opcode = Bytecode.INSTR_BRF;
        if ( $not!=null ) opcode = Bytecode.INSTR_BRT;
        gen.emit(opcode, -1); // write placeholder as branch target
		}
		template
		(	LDELIM i='elseif'
			{
			endRefs.add(gen.address()+1);
			gen.emit(Bytecode.INSTR_BR, -1); // br end
			// update previous branch instruction
			gen.write(prevBranchOperand, (short)gen.address());
			prevBranchOperand = -1;
			}
			'(' not2='!'? primary ')' RDELIM
			{
        	prevBranchOperand = gen.address()+1;
	        opcode = Bytecode.INSTR_BRF;
	        if ( $not2!=null ) opcode = Bytecode.INSTR_BRT;
        	gen.emit(opcode, -1); // write placeholder as branch target
			}
			template
		)*
		(	LDELIM 'else' RDELIM
			{
			endRefs.add(gen.address()+1);
			gen.emit(Bytecode.INSTR_BR, -1); // br end
			// update previous branch instruction
			gen.write(prevBranchOperand, (short)gen.address());
			prevBranchOperand = -1;
			}
			template
		)?
		LDELIM 'endif' RDELIM
		{
		if ( prevBranchOperand>=0 ) {
			gen.write(prevBranchOperand, (short)gen.address());
		}
        for (int opnd : endRefs) gen.write(opnd, (short)gen.address());
		}
	;

exprOptions
	:	{gen.emit(Bytecode.INSTR_OPTIONS);} option (',' option)*
	;

option
	:	ID ( '=' exprNoComma | {defaultOption($ID);} )
		{setOption($ID);}
	;
	
exprNoComma
	:	callExpr ( ':' templateRef {gen.emit(Bytecode.INSTR_MAP);} )?
	|	'{'
		{
//		String name = defineAnonTemplate($ANONYMOUS_TEMPLATE);
//        instance(new CommonToken(STRING,name)); // call anon template
        }
	;

expr : mapExpr ;

mapExpr
@init {int n=1;}
	:	callExpr
		(	':' templateRef
			(	(',' templateRef {n++;})+  {gen.emit(Bytecode.INSTR_ROT_MAP, n);}
			|						    {gen.emit(Bytecode.INSTR_MAP);}
			)
		)*
	;

callExpr
options {k=2;} // prevent full LL(*) which fails, falling back on k=1; need k=2
	:	{Compiler.funcs.containsKey(input.LT(1).getText())}?
		ID '(' arg ')' {func($ID);}
	|	ID {gen.emit(Bytecode.INSTR_NEW);} '(' args? ')'
	|	primary
	;
	
primary
	:	'super.' ('.' ID )*
	|	o=ID	  {refAttr($o);}
		(	'.' p=ID {gen.emit(Bytecode.INSTR_LOAD_PROP, $p.text);}
		|	'.' '(' mapExpr ')' {gen.emit(Bytecode.INSTR_LOAD_PROP_IND);}
		)*
	|	STRING    {gen.emit(Bytecode.INSTR_LOAD_STR, $STRING.text);}
	|	list
	|	'(' expr ')' {gen.emit(Bytecode.INSTR_TOSTR);}
		( {gen.emit(Bytecode.INSTR_NEW_IND);} '(' args? ')' )? // indirect call
	;

args:	arg (',' arg)* ;

arg :	ID '=' exprNoComma {gen.emit(Bytecode.INSTR_STORE_ATTR, $ID.text);}
	|	exprNoComma        {gen.emit(Bytecode.INSTR_STORE_SOLE_ARG);}
	|	elip='...'		   {gen.emit(Bytecode.INSTR_SET_PASS_THRU);}
	;

templateRef
	:	ID			{gen.emit(Bytecode.INSTR_LOAD_STR, $ID.text);}
	|	'{'
		{
//		String name = defineAnonTemplate($ANONYMOUS_TEMPLATE);
//		refString(new CommonToken(STRING,name));
		}
	|	'(' mapExpr ')' {gen.emit(Bytecode.INSTR_TOSTR);}
	;
	
list:	{gen.emit(Bytecode.INSTR_LIST);} '[' listElement (',' listElement)* ']'
	|	{gen.emit(Bytecode.INSTR_LIST);} '[' ']'
	;

listElement
    :   exprNoComma {gen.emit(Bytecode.INSTR_ADD);}
    ;