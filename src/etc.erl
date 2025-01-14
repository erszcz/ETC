-module(etc).
-import(erl_syntax,[
    function_clauses/1,
    fun_expr_clauses/1,
    clause_patterns/1,
    clause_body/1,
    clause_guard/1,
    type/1
]).

%% PRINT Debugging macro%%
-ifndef(PRINT).
-define(PRINT(Var), io:format("DEBUG: ~p:~p - ~p~n~n ~p~n~n", [?MODULE, ?LINE, ??Var, Var])).
-endif.

-export([parse_transform/2, lookup/3, infer/2, checkExpr/2]).

-export([main/1]).

-type lno() :: integer().
-type var() :: {var, lno(), atom()}.

-type expr() :: var() | {op,lno(),atom(),expr(),expr()}.

main(Args0) ->
    ets:new(compile_config, [set, named_table, public]),
    Args = ["+{parse_transform, tidy}"] ++ 
    case lists:member("+noti",Args0) of
        true -> [];
        false -> ["+{parse_transform, etc}"]
    end ++ 
    case lists:member("+pe",Args0) of
        true -> ["+{parse_transform, pe}"];
        false -> []
    end ++ Args0,
    erl_compile2:compile_cmdline(Args).

parse_transform(Forms,_) ->
    Module = pp:getModule(Forms),
    File = pp:getFile(Forms),
    case ets:lookup(compile_config, main_file) of
        [] ->  ets:insert(compile_config, {main_file, File});
         _  -> false
    end,
    case ets:lookup(compile_config, Module) of
        [] ->  ets:insert(compile_config, {Module, user_defined}),
            parse_transform_userdefined(Forms);
        [{Module, Type}] ->
            case Type of 
                stdlib -> parse_transform_stdlib(Forms);
                _ -> parse_transform_userdefined(Forms)
            end
    end.

 parse_transform_userdefined(Forms) ->
    Module = pp:getModule(Forms),
    File = pp:getFile(Forms),
    % add erlang module as the expected one.
    Mods = pp:getImprtdMods(Forms) ++ [erlang],
    dm:type_check_mods(Mods,File),

    % add UDTs to default env
    UDTs = pp:getUDTs(Forms),
    Env0 = lists:foldl(fun(UDT,AccEnv) ->
        convertUDT(AccEnv, UDT)
    end, env:default(), UDTs),

    % Get specs
    Specs = pp:getSpecs(Forms),
    SpecEnv = getSpecWithAllFuns(Env0, Specs),
    % ?PRINT(SpecEnv),
    EnvWithSpecs = env:addSpecs(Env0, SpecEnv),

    % add all user defined records
    Env1 = lists:foldl(fun(Rec,AccEnv) ->
        addRec(Rec,AccEnv) 
    end, EnvWithSpecs, pp:getRecs(Forms)),
    % add all depend external module functions
    Env = lists:foldl(fun(Mod, AccEnv) ->
        env:addExtModuleBindings(AccEnv, Mod)
    end, Env1, Mods),
    % get all functions
    Functions = pp:getFns(Forms),
    % make strongly connected components (SCCs) (sorted in topological ordering)
    SCCs = da:mkSCCs(Functions),
    % type check each SCC and extend Env
    try
        lists:foldl(fun(SCC, AccEnv) ->
            % typeCheckSCC(SCC, AccEnv)
            btc_typeCheckSCC(SCC, AccEnv)
        end, Env, SCCs)
    of  
        Env_ -> 
            env:dumpModuleBindings(Env_, Module),
            io:fwrite("Module ~p: ~n",[Module]),
            SortedBinds = lists:sort(env:readModuleBindings(Module)),
            lists:map(fun({X,T}) ->
                % TODO- VR we have to see
                % checkWithSpec(Spec, X, T),
                io:fwrite("  ~p :: ",[X]), 
                % ?PRINT(T),
                hm:pretty(T), 
                io:fwrite("~n",[])
            end, SortedBinds),
            io:fwrite("~n",[])
    catch
        error:{type_error,Reason} -> erlang:error("Type Error: " ++ Reason)
    end,
    pp:eraseAnn(Forms).

parse_transform_stdlib(Forms) ->
    Module = pp:getModule(Forms),
    File = pp:getFile(Forms),
    Mods = pp:getImprtdMods(Forms),
    dm:type_check_mods(Mods,File),
    % add UDTs to default env
    UDTs = pp:getUDTs(Forms),
    Env0 = lists:foldl(fun(UDT,AccEnv) ->
        convertUDT(AccEnv, UDT)
    end, env:default(), UDTs),

    % Get specs
    Specs = pp:getSpecs(Forms),
    SpecTypes = getSpecWithAllFuns(Env0, Specs),
    % we have to handle UDTs form lib
    env:dumpModuleSpecs(SpecTypes, Module),
    io:fwrite("Library Module:- ~p ~n",[Module]),
    lists:map(fun({X,T}) -> 
        io:fwrite("  ~p :: ",[X]),
        % [Head | _Tail] = T ,
        hm:pretty(T), 
        io:fwrite("~n",[])
    end, env:readModuleSpecs(Module)),
    io:fwrite("~n",[]),
    pp:eraseAnn(Forms).

typeCheckSCC(Functions, Env) ->
    % assign a fresh type variable to every function
    FreshEnv = lists:foldl(fun(F,AccEnv) -> 
        FunQName = util:getFnQName(F), 
        env:extend(FunQName, hm:fresh(util:getLn(F)), AccEnv)
    end, Env, Functions),
    {InfCs,InfPs} = lists:foldl(fun(F, AccCsPs) ->
        inferOrCheck(FreshEnv, F, AccCsPs)
        % btc_synth_check(FreshEnv, F, AccCsPs)
    end, {[],[]}, Functions),

    %% Add all specs to Env
    EnvWithSpec = lists:foldl(fun(F, AccEnv) ->
        FunQName = util:getFnQName(F),
        Specs = env:getSpecs(Env),
        case spec:hasUserSpecifiedSpec(Specs, FunQName) of
            true -> 
                FT = spec:getFirstSpecType(Specs, FunQName),
                env:extend(FunQName, FT, AccEnv);
            false -> AccEnv
        end
    end, FreshEnv, Functions),
    % Solve unification constraints
    Sub             = hm:solve(InfCs),
    Ps              = hm:subPs(InfPs,Sub),
    % predicate solving leads in a substitution since 
    % oc predicates are basically ambiguous unification constraints
    {Sub_, RemPs}   = hm:solvePreds(rt:defaultClasses(), Ps),
    SubdEnv = hm:subE(EnvWithSpec, hm:comp(Sub_,Sub)), 
    lists:foldl(fun(F, AccEnv) ->
        FunQName = util:getFnQName(F),
        %lookup type from the substituted environment
        {T,_}  = lookup(FunQName, SubdEnv, util:getLn(F)),
        % generalize type wrt given environment
        PolyT   = hm:generalize(T, AccEnv, RemPs),
        env:extend(FunQName, PolyT, AccEnv)
    end, Env, Functions).

inferOrCheck(Env, F, {AccCs, AccPs}) ->
    FunQName = util:getFnQName(F),
    Specs = env:getSpecs(Env),
    {FreshT,_} = lookup(FunQName, Env, util:getLn(F)),
    case spec:hasUserSpecifiedSpec(Specs, FunQName) of
        false ->
            %% TODO REmove VR %%
            % {T,Cs,Ps} = infer(Env,F),
            {_Env, T} = btc:type_check(Env, F),
            {AccCs, AccPs},
            { unify(T, FreshT) ++ AccCs , AccPs};
        true -> 
            {_Env, T} = btc:type_check(Env, F),
            {AccCs, AccPs}
    end.


btc_typeCheckSCC(Functions, Env) ->
    FreshEnv = btc:addFuncSkeltons(Env, Functions),
    %% Add all specs to Env
    EnvWithSpec = lists:foldl(fun(F, AccEnv) ->
        FunQName = util:getFnQName(F),
        Specs = env:getSpecs(Env),
        case spec:hasUserSpecifiedSpec(Specs, FunQName) of
            true -> 
                FT = spec:getFirstSpecType(Specs, FunQName),
                env:extend(FunQName, FT, AccEnv);
            false -> AccEnv
        end
    end, FreshEnv, Functions),
    {CheckedEnv, _Types} = lists:foldl(fun(F, {AccEnv, Ts}) ->
        % inferOrCheck(FreshEnv, F, AccCsPs)
        {E, T} = btc:type_check(AccEnv, F),
        {E, Ts ++ [T]}
    end, {EnvWithSpec,[]}, Functions),
    % ?PRINT(Types),
    lists:foldl(fun(F, AccEnv) ->
        FunQName = util:getFnQName(F),
        %lookup type from the substituted environment
        % ?PRINT(FunQName),
        {T,_}  = lookup(FunQName, CheckedEnv, util:getLn(F)),
        % ?PRINT(T),
        env:extend(FunQName, T, AccEnv)
    end, Env, Functions).

-spec infer(hm:env(), erl_syntax:syntaxTree()) ->
    {hm:type(),[hm:constraint()],[hm:predicate()]}.
infer(_,{integer,L,_}) -> 
    X = hm:fresh(L),
    {X,[],[{class,"Num",X}]};
infer(_, {string,L,_}) ->
    {hm:tcon("list", [hm:bt(char,L)],L),[],[]};
infer(_,{char,L,_}) ->
    {hm:bt(char,L),[],[]};
infer(_,{float,L,_}) ->
    {hm:bt(float,L),[],[]};
infer(Env,{clause,L,_,_,_}=Node) ->
    ClausePatterns = clause_patterns(Node),
    % ?PRINT(ClausePatterns),
    % Infer types of arguments (which are in the form of patterns)
    % Env_ is Env extended with arg variables
    {ArgTypes, Env_, CsArgs, PsArgs} = inferPatterns(Env,ClausePatterns),
    ClauseGaurds = clause_guard(Node),
    {CsGaurds, PsGaurds} = checkGaurds(Env_,ClauseGaurds),
    % ?PRINT(CsGaurds),
    % ?PRINT(PsGaurds),
    {ReturnType, CsBody, PsBody} = inferClauseBody(Env_,clause_body(Node)),
    {hm:funt(ArgTypes,ReturnType,L)
    , CsArgs ++ CsGaurds ++ CsBody
    , PsArgs ++ PsGaurds ++ PsBody};
infer(_,{var,L,'_'}) ->
    {hm:fresh(L),[],[]};
infer(Env,{var, L, X}) ->
    {T, Ps} = lookup(X, Env, L),
    {T, [], Ps};
infer(Env,{call,L,{atom,_,is_function},[F,{integer,_,Arity}]}) ->
    {TF,CsF,PsF} = infer(Env,F),
    ArgTypes = lists:map(fun hm:fresh/1, lists:duplicate(Arity,L)),
    {hm:bt(boolean,L),CsF ++ unify(TF, hm:funt(ArgTypes,hm:fresh(L),L)),PsF};
infer(Env,{call,L,{atom,_,element},[{integer,_,N},{tuple,_,Es}]}) ->
    case N =< length(Es) of
        false -> erlang:error({type_error,
            "Index to element must be at least the length of the tuple on " ++ util:to_string(L)});
        true -> 
            {Ts,Cs,Ps} = lists:foldl(
                        fun(X, {AccT,AccCs,AccPs}) -> 
                            {T,Cs,Ps} = infer(Env,X),
                            {AccT ++ [T], AccCs ++ Cs, AccPs ++ Ps}
                        end, {[],[],[]}, Es),
            {lists:nth(N,Ts),Cs,Ps}
    end;
infer(Env,{call,L,F,Args}) ->
    {T1,Cs1,Ps1} = inferFn(Env,F,length(Args)),
    %% disable guard check for non functions
    Env_ = env:disableGuardExprEnv(Env),
    {T2,Cs2,Ps2} = lists:foldl(
        fun(X, {AccT,AccCs,AccPs}) -> 
            {T,Cs,Ps} = infer(Env_,X),
            {AccT ++ [T], AccCs ++ Cs, AccPs ++ Ps}
        end
        , {[],[],[]}, Args),
    V = hm:fresh(L),
    {V, Cs1 ++ Cs2 ++ unify(T1, hm:funt(T2,V,L)), Ps1 ++ Ps2};
infer(Env,{op,L,Op,E1,E2}) ->
    {T, Ps} = lookup(Op, Env,L),
    {T1, Cs1, Ps1} = infer(Env, E1),
    {T2, Cs2, Ps2} = infer(Env, E2),
    V = hm:fresh(L),
    {V, Cs1 ++ Cs2 ++ unify(T, hm:funt([T1,T2],V,L)), Ps ++ Ps1 ++ Ps2};
infer(Env,{atom,L,X}) ->
    case X of
        B when is_boolean(B) ->
            {hm:bt(boolean,L),[],[]};
        _ -> 
            % lookup if atom is a nullary constructor
            case lookupConstrs({X,0},Env,L) of   
                {nothing} -> {hm:bt(atom,L),[],[]};
                {just,{ConstrTypes,ConstrPs}} ->
                    V = hm:fresh(L),
                    {V, [], [{oc,hm:funt([],V,L),ConstrTypes}] ++ ConstrPs}
            end
    end;
infer(Env,{'fun',L,{function,X,ArgLen}}) ->
    {T, Ps} = lookup({X,ArgLen},Env,L),
    {T,[],Ps};
infer(_,{nil,L}) ->
    {hm:tcon("list",[hm:fresh(L)],L),[],[]};
infer(Env,{cons,L,H,T}) ->
    {HType,HCs,HPs} = infer(Env, H),
    {TType,TCs,TPs} = infer(Env, T),
    % generate a fresh "List V"
    V = hm:fresh(L), 
    LType = hm:tcon("list", [V],L),
    {LType, HCs ++ TCs ++ 
        unify(HType,V) ++   % unify head type with "V" 
        unify(TType,LType)  % unify tail type with "List V"
    , HPs ++ TPs};
infer(Env,{tuple,L,Es}) ->
    % lazy treatement of tuple as a tuple (not constructor)
    TupleTyping = fun() ->
        {Ts,Cs,Ps} = lists:foldl(
                        fun(X, {AccT,AccCs,AccPs}) -> 
                            {T,Cs,Ps} = infer(Env,X),
                            {AccT ++ [T], AccCs ++ Cs, AccPs ++ Ps}
                        end, {[],[],[]}, Es),
        {hm:tcon("tuple",Ts,L),Cs,Ps}
    end,
    case Es of
        % if first element of tuple is an atom,
        [{atom,_,_}=HeadEl|TailEls]   ->
            % then consider it as a constructor
            {atom,L,Constructor} = HeadEl,
            % and the tail as arguments to constructor
            Args = TailEls,
            case lookupConstrs({Constructor,length(Args)},Env,L) of
                {nothing} -> TupleTyping();
                {just,{ConstrTypes,ConstrPs}}  -> 
                    {ArgTypes,ArgCs,ArgPs}  = lists:foldl(fun(X, {AccT,AccCs,AccPs}) -> 
                        {T,Cs,Ps} = infer(Env,X),
                        {AccT ++ [T], AccCs ++ Cs, AccPs ++ Ps}
                    end, {[],[],[]}, Args),
                    V = hm:fresh(L),
                    {V, ArgCs, [{oc,hm:funt(ArgTypes,V,L),ConstrTypes}] ++ ConstrPs ++ ArgPs}
            end;
        _           -> TupleTyping()
    end;
infer(Env,{'if',_,Clauses}) ->
    {ClauseTs, Cs, Ps} = inferClauses(Env,Clauses),
    BodTs = getTypesOfBodies(ClauseTs),
    { lists:last(BodTs)
    , Cs ++ unify(BodTs)
    , Ps};
infer(Env,{'case',_,Expr,Clauses}) ->
    {EType,ECs,EPs} = infer(Env,Expr),
    {ClauseTs, Cs, Ps} = inferClauses(Env,Clauses),
    PatTs = lists:map(fun({[PT],_}) -> PT end, ClauseTs),
    BodTs = getTypesOfBodies(ClauseTs),
    { lists:last(BodTs)
    , ECs ++ Cs ++ unify(PatTs) ++ unify(BodTs) ++ unify(EType,lists:last(PatTs))
    , EPs ++ Ps};
infer(Env,{'receive',_,Clauses}) ->
    {ClauseTs, Cs, Ps} = inferClauses(Env,Clauses),
    PatTs = lists:map(fun({[PT],_}) -> PT end, ClauseTs),
    BodTs = getTypesOfBodies(ClauseTs),
    { lists:last(BodTs)
    , Cs ++ unify(PatTs)++ unify(BodTs)
    , Ps};
infer(Env,{match,_,LNode,RNode}) ->
    {Env_, Cons1, Ps} = checkExpr(Env,LNode),
    {LType, Cons2, PsL} = infer(Env_,LNode),
    {RType, Cons3, PsR} = infer(Env,RNode),
    { RType
    , Cons1 ++ Cons2 ++ Cons3 ++ unify(LType,RType)
    , Ps ++ PsL ++ PsR};
infer(Env,{lc,L,Expr,Defs}) ->
    {Env_,DefCs,DefPs} = checkLCDefs(Env,Defs),
    {T, ExprCs, ExprPs} = infer(Env_,Expr),
    {hm:tcon("list", [T],L), DefCs ++ ExprCs, DefPs ++ ExprPs};
infer(Env,{block,_,Exprs}) ->
    {Env_, CsBody, PsBody} = lists:foldl(fun(Expr, {Ei,Csi,Psi}) -> 
        {Ei_,Csi_,Psi_} = checkExpr(Ei,Expr),
        {Ei_, Csi ++ Csi_, Psi ++ Psi_}
    end, {Env,[],[]}, lists:droplast(Exprs)),
    {TLast, CsLast, PsLast} = infer(Env_, lists:last(Exprs)),
    {TLast, CsBody ++ CsLast, PsBody ++ PsLast};
% Create a record value
infer(Env,{record,L,Rec,FieldValues}) ->
    {RConstrType,RecFields,Ps0} = lookupRecord(Rec,Env,L),
    {funt,_,As,_} = RConstrType,
    {ArgTs, ArgCs, ArgPs} = lists:foldr(fun({F,ExpectedType},{AccTs,AccCs,AccPs}) ->
        Field = getField(F),
        GivenValue = getRecFieldValue(Field,FieldValues),
        {InfT,InfCs,InfPs} =
            case GivenValue of
                % value not given
                {nothing}   ->
                    case getDefaultValue(F) of
                        % no default value, no given type
                        {nothing}   -> 
                            case env:isPatternInf(Env)  of
                                true    ->  {hm:fresh(L),[],[]};
                                false   ->   {hm:bt(undefined,L),[],[]}
                            end;
                        % default value is available
                        {just,DV}    -> infer(Env,DV)
                    end;
                % value given, (type is inferred type of given value)
                {just,V} ->
                    infer(Env,V)
            end,
        {[InfT|AccTs],InfCs ++ unify(InfT,ExpectedType) ++ AccCs, InfPs ++ AccPs}
    end, {[],[],[]}, lists:zip(RecFields,As)),
    V = hm:fresh(L),
    {V, ArgCs ++ unify(RConstrType, hm:funt(ArgTs,V,L)), Ps0 ++ ArgPs};
% Update a record
infer(Env,{record,L,Expr,Rec,FieldValues}) ->
    {ExprT, ExprCs, ExprPs} = infer(Env,Expr),
    {RConstrType0,RecFields0,Ps0} = lookupRecord(Rec,Env,L),
    {funt,_,As,B} = RConstrType0,
    % Construct the types of argments from the types of arguments to constructor
    {ArgTs, ArgCs, ArgPs} = lists:foldr(fun({F,ExpectedType},{AccTs,AccCs,AccPs}) ->
        Field = getField(F),
        GivenValue = getRecFieldValue(Field,FieldValues),
        {InfT,InfCs,InfPs} = 
            case GivenValue of
                % value not given (use type of field in Expr)
                {nothing}   -> 
                    {ExpectedType,[],[]};
                % value given, (type is inferred type of given value)
                {just,V} ->
                    infer(Env,V)
            end,
        {[InfT|AccTs],InfCs ++ AccCs, InfPs ++ AccPs}
    end, {[],[],[]}, lists:zip(RecFields0,As)),
    {RConstrType1,_,Ps1} = lookupRecord(Rec,Env,L),
    V = hm:fresh(L),
    { V
    , ExprCs ++ ArgCs ++ unify(RConstrType1, hm:funt(ArgTs,V,L)) ++ unify(B,ExprT)
    , ExprPs ++ Ps0 ++ Ps1 ++ ArgPs};
% Access a record
infer(Env,{record_field,L,Expr,Rec,{atom,_,Field}}) ->
    {ExprT, ExprCs, ExprPs} = infer(Env,Expr),
    {RConstrType0,RecFields0,Ps0} = lookupRecord(Rec,Env,L),
    {funt,_,As,B} = RConstrType0,
    T = findFieldType(Field,RecFields0,As),
    {T,ExprCs ++ unify(B,ExprT),ExprPs ++ Ps0};  
infer(Env,{'try',L,TryExprs,[],CatchClauses,AfterExprs}) ->
    %infer type of try
    {TrT,TrCs,TrPs} = inferExprs(Env,TryExprs),
    %infer type of catch
    {CatchClauseTs, CatchCs, CatchPs} = inferClauses(Env,CatchClauses),
    CatchBodTs = getTypesOfBodies(CatchClauseTs),
    case AfterExprs of
        [] -> 
            {TrT
            ,TrCs ++ CatchCs ++ unify([TrT|CatchBodTs])
            ,TrPs ++ CatchPs};
        _  -> 
            {AfterT, AfterCs, AfterPs} = inferExprs(Env,TryExprs),
            {AfterT
            , TrCs ++ CatchCs ++ unify([TrT|CatchBodTs]) ++ AfterCs
            ,TrPs ++ CatchPs ++ AfterPs}
    end;     
infer(Env,Node) ->
    case type(Node) of
        Fun when Fun =:= function; Fun =:= fun_expr ->
            Clauses = case Fun of 
                function -> function_clauses(Node);
                fun_expr -> fun_expr_clauses(Node)
            end,
            % list of clause inference results
            ClausesInfRes = lists:map(fun(C) -> infer(Env,C) end, Clauses),
            % ?PRINT(ClausesInfRes),
            % "flatten" clause inference results
            {InfTypes, InfCs, InfPs} = lists:foldr(
                fun({T,Cs,Ps}, {AccTypes,AccCs,AccPs}) 
                    -> {[T|AccTypes], Cs ++ AccCs, Ps ++ AccPs} 
                end
                , {[],[],[]}, ClausesInfRes),
            % Unify the types of all clauses 
            UniCs = unify(InfTypes),
            % pick the type of any one clause as the type of fn
            {lists:last(InfTypes), InfCs ++ UniCs, InfPs};
        X -> erlang:error({type_error," Cannot infer type of " 
            ++ util:to_string(Node) ++ " with node type "++ util:to_string(X)})
    end.

inferExprs(Env,Exprs) ->
    {Env_, CsBody, PsBody} = lists:foldl(fun(Expr, {Ei,Csi,Psi}) -> 
            {Ei_,Csi_,Psi_} = checkExpr(Ei,Expr),
            {Ei_, Csi ++ Csi_, Psi ++ Psi_}
        end, {Env,[],[]}, lists:droplast(Exprs)),
    {TLast, CsLast, PsLast} = infer(Env_, lists:last(Exprs)),
    {TLast, CsBody ++ CsLast, PsBody ++ PsLast}.

-spec checkExpr(hm:env(), erl_syntax:syntaxTree()) ->
    {hm:env(),[hm:constraint()],[hm:predicate()]}.
checkExpr(Env,{match,_,LNode,RNode}) ->
    {Env1, Cons1, Ps1} = checkExpr(Env,LNode),
    % hack to allow bindings new variables on left in patterns :(
    {Env2, Cons2, Ps2} = checkExpr(Env1,RNode),
    {LType, ConsL, PsL} = infer(Env1,LNode),
    {RType, ConsR, PsR} = infer(Env2,RNode),
    { Env2
    , Cons1 ++ Cons2 ++ ConsL ++ ConsR ++ unify(LType,RType)
    , Ps1 ++ Ps2 ++ PsL ++ PsR};
checkExpr(Env,{var,L,X}) ->
    case env:is_bound(X,Env) of
        true    -> {Env,[],[]};
        false   -> {env:extend(X,hm:fresh(L),Env), [],[]}
    end;
checkExpr(Env,{tuple,_,Es}) ->
    % TODO handle constructors separately!
    lists:foldl(fun(E, {AccEnv,AccCs,AccPs}) ->
        {ChEnv,ChCs,ChPs} = checkExpr(AccEnv,E),
        {ChEnv, AccCs ++ ChCs, AccPs ++ ChPs}
    end, {Env,[],[]}, Es);
checkExpr(Env,{block,_,Es}) ->
    lists:foldl(fun(E, {AccEnv,AccCs,AccPs}) ->
        {ChEnv,ChCs,ChPs} = checkExpr(AccEnv,E),
        {ChEnv, AccCs ++ ChCs, AccPs ++ ChPs}
    end, {Env,[],[]}, Es);
checkExpr(Env,{cons,_,H,T}) ->
    {Env_,HCs,HPs} = checkExpr(Env,H),
    {Env__,TCs,TPs} = checkExpr(Env_,T),
    {Env__,HCs ++ TCs, HPs ++ TPs};
checkExpr(Env,{'if',L,Clauses}) ->
    Env_ = addCommonBindings(Clauses,Env,L),
    {_, Cs, Ps} = inferClauses(Env_,Clauses),
    {Env_ , Cs, Ps};
checkExpr(Env,{'case',L,Expr,Clauses}) ->
    {EType,ECs,EPs} = infer(Env,Expr),
    Env_ = addCommonBindings(Clauses,Env,L),
    {ClauseTs, Cs, Ps} = inferClauses(Env_,Clauses),
    PatTs = lists:map(fun({[PT],_}) -> PT end, ClauseTs),
    { Env_
    , ECs ++ Cs ++ unify(PatTs) ++ unify(EType,lists:last(PatTs))
    , EPs ++ Ps};
checkExpr(Env,{'receive',L,Clauses}) ->
    Env_ = addCommonBindings(Clauses,Env,L),
    {ClauseTs, Cs, Ps} = inferClauses(Env_,Clauses),
    PatTs = lists:map(fun({[PT],_}) -> PT end, ClauseTs),
    { Env_
    , Cs ++ unify(PatTs)
    , Ps};
checkExpr(Env,{record,L,_,FieldExprs}) ->
    lists:foldl(fun(F, {AccEnv,AccCs,AccPs}) ->
        Field = getField(F),
        case getRecFieldValue(Field,FieldExprs) of
            {just,V} ->
                {ChEnv,ChCs,ChPs} = checkExpr(AccEnv,V),
                {ChEnv, AccCs ++ ChCs, AccPs ++ ChPs}
        end
    end, {Env,[],[]}, FieldExprs);
checkExpr(Env,ExprNode) ->
    {_,Cs,Ps} = infer(Env, ExprNode),
    {Env,Cs,Ps}.

% infer the types of patterns in arguments of function definition
-spec inferPatterns(hm:env(),[erl_syntax:syntaxTree()]) -> 
    {[hm:types()],hm:env(),[hm:constraint()],[hm:predicate()]}.
inferPatterns(Env,ClausePatterns) ->
    lists:foldl(
        fun(Pattern,{AccTs,AccEnv,AccCs,AccPs}) ->
            {Env_, _, _} = checkExpr(AccEnv,Pattern),
            {InfT, InfCs, InfPs} = infer(env:setPatternInf(Env_),Pattern),
            {AccTs ++ [InfT], Env_, AccCs ++ InfCs, AccPs ++ InfPs }
        end, {[],Env,[],[]} ,ClausePatterns).

% infer the type of expression on the left of an application
-spec inferFn(hm:env(),erl_syntax:syntaxTree(),integer()) -> 
    {hm:type(),[hm:constraint()],[hm:predicate()]}.
inferFn(Env,{atom,L,X},ArgLen) ->
    {T, Ps} = lookup({X,ArgLen},Env,L), {T,[],Ps};
inferFn(Env,{remote,L,{atom,_,Module},{atom,_,X}},ArgLen) ->
    {T, Ps} = lookupRemote({X,ArgLen},Env,L,Module), {T,[],Ps};
inferFn(Env,X,_) ->
    infer(Env,X).

% check that the guards are all boolean
-spec checkGaurds(hm:env(),erl_syntax:syntaxTree()) -> 
    {[hm:constraint()],[hm:predicate()]}.
checkGaurds(Env,{tree,disjunction,_,Conjuctions}) ->
    lists:foldr(fun({tree,conjunction,_,Exprs}, {DAccCs, DAccPs}) ->
        {Cs,Ps} = lists:foldr(fun(Expr,{CAccCs,CAccPs}) -> 
            {InfT,InfCs,InfPs} = infer(env:enableGuardExprEnv(Env),Expr),
            { unify(InfT,hm:bt(boolean,hm:getLn(InfT))) ++ InfCs ++ CAccCs
            , InfPs ++ CAccPs} 
        end, {[],[]}, Exprs),
        {Cs ++ DAccCs, Ps ++ DAccPs}
   end, {[],[]}, Conjuctions);
checkGaurds(_,none) -> {[],[]}.

% given a body of a clause, returns its type
-spec inferClauseBody(hm:env(),erl_syntax:syntaxTree()) ->
    {hm:type(),[hm:constraint()],[hm:predicate()]}.
inferClauseBody(Env,Body) -> 
    {Env_, CsBody, PsBody} = lists:foldl(
                    fun(Expr, {Ei,Csi,Psi}) -> 
                        {Ei_,Csi_,Psi_} = checkExpr(Ei,Expr),
                        {Ei_, Csi ++ Csi_, Psi ++ Psi_}
                    end, {Env,[],[]}, lists:droplast(Body)),
    {TLast, CsLast, PsLast} = infer(Env_, lists:last(Body)),
    {TLast, CsBody ++ CsLast, PsBody ++ PsLast}.

% Used to infer the type of a list of clauses
% given a list of clauses, it returns a tuple of: 
% 1. list of clause types i.e., [{PatternTypes,BodyType}]
% 2. all constraints inferred in the process
% 3. all predicates which arise in the process
-spec inferClauses(hm:env(),[erl_syntax:syntaxTree()]) -> 
    {[{[hm:type()], hm:type()}], [hm:constraint()],[hm:predicate()]}.
inferClauses(Env,Clauses) ->
    lists:foldr(fun(Clause,{AccClauseTs,AccCs,AccPs}) ->
        % infer type of pattern
        {PatTypes,Env_,PatCs,PatPs} = inferPatterns(Env,clause_patterns(Clause)),
        % check clause guards
        {GaurdsCs, GaurdsPs} = checkGaurds(Env_,clause_guard(Clause)),
        % infer type of body
        {BodyType, BodyCs, BodyPs} = inferClauseBody(Env_,clause_body(Clause)),
        {  [{PatTypes, BodyType} | AccClauseTs], 
            PatCs ++ GaurdsCs ++ BodyCs  ++ AccCs, 
            PatPs ++ GaurdsPs ++ BodyPs  ++ AccPs}
    end, {[],[],[]}, Clauses).

getTypesOfBodies(ClauseTs) -> lists:map(fun({_,BT}) -> BT end, ClauseTs).

% check the types of the list comprehension defns (generators and filters)
% te resulting env is used for type inference of the main expression in lc
-spec checkLCDefs(hm:env(), [erl_syntax:syntaxTree()]) -> 
    {hm:env(),[hm:constraint()],[hm:predicate()]}.
checkLCDefs(Env,Exprs) ->
    % fold over lc defs & accumulate env, cs & ps
    lists:foldl(fun(Expr,{AccEnv,AccCs,AccPs}) ->
        case Expr of
            % generators must be a list
            {generate,L,{var,_,X},List} ->
                {ActualListType,Cs,Ps} = infer(AccEnv,List),
                XType = hm:fresh(L),
                ExpectedListType = hm:tcon("list", [XType],L),
                {env:extend(X,XType,AccEnv) 
                    , unify(ActualListType,ExpectedListType) ++ Cs ++ AccCs
                    , Ps ++ AccPs};
            % filter must be boolean
            _   ->
                {ActualType,Cs,Ps} = infer(AccEnv,Expr),
                ExpectedType = hm:bt(boolean,hm:getLn(ActualType)),
                {AccEnv
                    , unify(ActualType,ExpectedType) ++ Cs++ AccCs
                    , Ps ++ AccPs}
        end
    end,{Env,[],[]},Exprs).
    
%%%%%%%%%%%%%%%%%% Utilities

% "pseudo unify" which returns constraints
-spec unify([hm:type()]) -> [hm:constraint()].
unify(Types) ->
    {Constraints, RemType} = util:pairwiseChunk(Types),
    RemConstraints = 
        case RemType of
            {nothing} -> [];
            {just, X} -> 
                case length(Constraints) of
                    L when L > 0    -> [{X, element(2,lists:last(Constraints))}];
                    _               -> []
                end
        end,
    Constraints ++ RemConstraints.

% "pseudo unify" which returns constraints
-spec unify(hm:type(),hm:type()) -> [hm:constraint()].
unify(Type1,Type2) -> [{Type1,Type2}].

-spec lookup(hm:tvar(),hm:env(),integer()) -> {hm:type(),[hm:predicate()]}.
lookup(X,Env,L) ->
    case env:isGuardExprEnabled(Env) of
        false -> lookup_(X,Env,L);
        true  -> 
            case env:checkGuard(X,Env) of
                undefined   ->
                    lookup_(X, Env, L);
                    % non supported guard will be a compiler error
                    % ,erlang:error({type_error,util:to_string(X) ++ 
                    %     " unsupported guard on line " ++ util:to_string(L)});
                T           ->
                    {FT, Ps} = hm:freshen(T),
                    {hm:replaceLn(FT, 0, L), Ps}
            end
    end.

-spec lookup_(hm:tvar(),hm:env(),integer()) -> {hm:type(),[hm:predicate()]}.
lookup_(X,Env,L) ->
    case env:lookup(X,Env) of
        undefined   ->
            case env:lookup_ext_binding(X,Env) of 
                undefined -> 
                    erlang:error({type_error,util:to_string(X) ++ 
                        " not bound on line " ++ util:to_string(L)});
                ET        ->
                    {FT,Ps} = hm:freshen(ET),
                    {hm:replaceLn(FT,0,L),Ps}
            end;
        T           ->
            {FT,Ps} = hm:freshen(T),
            {hm:replaceLn(FT,0,L),Ps}
    end.

lookupRemote(X,Env,L,Module) ->
    case env:lookupRemote(Module, X, Env) of
        undefined   ->
             erlang:error({type_error,util:to_string(X) ++ 
                            " on line " ++ util:to_string(L) ++ 
                            " is not exported by module " ++ util:to_string(Module)});
        na          ->
            {_,ArgLen} = X,
            ArgTypes = lists:map(fun hm:fresh/1, lists:duplicate(ArgLen,L)),
            {hm:funt(ArgTypes,hm:fresh(L),L),[]};
        T           -> 
            {FT,Ps} = hm:freshen(T), 
            {hm:replaceLn(FT,0,L),Ps}
    end.

-spec lookupConstrs(hm:tvar(),hm:env(),integer()) -> {[hm:type()],[hm:predicate()]}.
lookupConstrs(X,Env,L) ->
    case env:lookupConstrs(X,Env) of
        []   -> {nothing};
        Ts   -> {just,lists:foldr(fun(T,{AccTs,AccPs}) -> 
                            {FT,FPs} = hm:freshen(T),
                            {[hm:replaceLn(FT,0,L)|AccTs], FPs ++ AccPs}
                end, {[],[]} ,Ts)}
    end.

lookupRecord(X,Env,L) ->
     case env:lookupRecord(X,Env) of
        undefined   -> 
            erlang:error({type_error,"Record " ++ util:to_string(X) ++ 
                " not bound on line " ++ util:to_string(L)});
        {RConstrType,RecFields}           -> 
            {FT,Ps} = hm:freshen(RConstrType),
            {hm:replaceLn(FT,0,L),RecFields,Ps}
    end.

-spec addUDTNode(hm:env(),erl_syntax:syntaxTree()) -> hm:env().
addUDTNode(Node,Env) ->
    addUDT(element(4,Node),Env,util:getLn(Node)).

-spec addUDT(hm:env(),erl_syntax:syntaxTree(),integer()) -> hm:env().
addUDT({TypeConstr,DataConstrs,Args},Env,L) ->
    % make type constructor
    Type = hm:tcon(TypeConstr,lists:map(fun node2type/1, Args),L),

    % add every data constructor to Env
    lists:foldl(fun({DConstr,DConstrType}, AccEnv) ->
        PolyDConstrType = hm:generalize(DConstrType,Env,[]),
        env:extendConstr(DConstr,PolyDConstrType,AccEnv)
    end, Env, getConstrTypes(Type, DataConstrs)).

% returns a list of Env entries - one for each data constructor
-spec getConstrTypes(hm:type(),erl_syntax:syntaxTree()) -> [{var(),hm:type()}].
getConstrTypes(Type,{atom,L,DataConstr}) ->
    [{{DataConstr,0},hm:funt([],Type,L)}];
getConstrTypes(Type,{type,L,tuple,[{atom,_,DataConstr}|Args]}) ->
    ArgTypes = lists:map(fun node2type/1, Args),
    [{{DataConstr,length(Args)},hm:funt(ArgTypes,Type,L)}];
getConstrTypes(_Type,{type,_L,tuple,_Args}) ->
    [];
getConstrTypes(Type,{type,_,union,DataConstrDefns}) -> 
    lists:concat(
        lists:map(
            fun(DCD) -> getConstrTypes(Type,DCD) end, DataConstrDefns));
getConstrTypes(Type, {type, L, BuiltInType, []}) ->
    [{{BuiltInType,0}, hm:funt([hm:bt(BuiltInType, 0)],Type, L)}];
getConstrTypes(Type, {user_type, L, UserType, []}) ->
    [{{UserType,0}, hm:funt([hm:bt(UserType, 0)], Type, L)}];
getConstrTypes(Type, DataConstrs) ->
    % ?PRINT(Type),
    % ?PRINT(DataConstrs),
    [].

% converts a type (node) in the AST to a hm:type()
-spec node2type(erl_syntax:syntaxTree()) -> hm:type().
node2type({var,L,'_'}) -> hm:bt(any, L);
node2type({var,L,X}) -> hm:tvar(X, L);
node2type({type,L,nonempty_improper_list, [CT, _TT]}) ->
    % Terminal type needed to be taken cared of
    hm:tcon("list",[node2type(CT)],L);
node2type({type,L,list,[]}) ->
    hm:tcon("list",[hm:fresh(L)],L);
node2type({type,L,nil,[]}) ->
    %TODO not sure we have to handle different
    hm:tcon("list",[hm:fresh(L)],L);
node2type({type, L, non_neg_integer,[]}) ->
    %TODO we have to remove
    % ?PRINT(L),
    hm:tcon("union", [hm:bt(integer, L), hm:bt(float, L)], L);
node2type({type, L, pos_integer, []}) ->
    %TODO we have to remove once we support sub typing relation for integer +ve -ve integer
    hm:tcon("union", [hm:bt(integer, L), hm:bt(float, L)], L);
node2type({type, L, number, []}) ->
    %TODO we have to remove once we support sub typing relation for integer +ve -ve integer
    hm:tcon("union", [hm:bt(integer, L), hm:bt(float, L)], L);
node2type({type,L,T,[]}) -> hm:bt(T,L);
node2type({type,L,tuple, any}) -> hm:tcon("tuple",[],L);
node2type({type,L,tuple,Args}) -> hm:tcon("tuple",lists:map(fun node2type/1, Args),L);
node2type({type,L,list, Args}) ->
    hm:tcon("list", lists:map(fun node2type/1, Args),L);
node2type({type, L, nonempty_list, Args}) ->
    ?PRINT(Args),
    % TODO not sure we have to handle different
    hm:tcon("list", lists:map(fun node2type/1, Args), L);
node2type({type,L,union,Args}) -> hm:tcon("union",lists:map(fun node2type/1, Args), L);
node2type({type, L, map, any}) ->
    AnyToAny = hm:tcon("key-value",[hm:bt(any, L), hm:bt(any, L)],L),
    hm:tcon("map", [AnyToAny], L);
node2type({type, L, map, Args}) ->  hm:tcon("map",lists:map(fun node2type/1, Args), L);
node2type({type, L, map_field_assoc, Args}) -> hm:tcon("key-value",lists:map(fun node2type/1, Args),L);
node2type({ann_type,_L,[_TVar, TNode]}) -> node2type(TNode);
node2type({user_type,L,T,Args}) -> hm:tcon(T,lists:map(fun node2type/1, Args),L);
node2type({type,L,'fun', [Args, RType]}) -> hm:funt(node2types(Args), node2type(RType), L);
node2type({type,_L,'bounded_fun', [Func, Constraints]}) ->
    FunT = node2type(Func),
    % TODO : clean up
    CTypes = lists:map(fun node2Constraint/1, Constraints),
    CTMap = lists:foldl(fun({VarT, Type}, Map) ->
        %Update the type line number
        % NewVarT = hm:replaceLn(VarT,hm:getLn(VarT), hm:getLn(FunT)),
        maps:put(tVarName(VarT), Type, Map)
    end, maps:new(), CTypes),
    % ?PRINT(FunT),
    % ?PRINT(CTMap),
    CTMap_ = applyCtrsToCtrs(CTMap),
    % ?PRINT(CTMap_),
    % ?PRINT(FunT),
    NT = applyConstraints(FunT, CTMap_),
    NT;

node2type({atom,_L,true}) -> 
    hm:bt(boolean,0);
node2type({atom,_L,false}) -> 
    hm:bt(boolean,0);
node2type({atom,_L, atom}) -> 
    hm:bt(atom,0);
node2type({atom,_L, _}) -> 
    hm:bt(atom,0);
node2type(Node) ->
    ?PRINT(Node),
    hm:bt(any, 0).

% converts a type (node) in the AST to a list of hm:type()
-spec node2types(erl_syntax:syntaxTree()) -> [hm:type()].
node2types({type,_,product, Types}) ->
    lists:map(fun node2type/1, Types);
node2types({type,_,union, Types}) ->
    lists:map(fun node2type/1, Types).

node2Constraint({type,_L,constraint,[_CType,[Var, Type]]}) ->
    % ?PRINT(Var),
    % ?PRINT(Type),
    {node2type(Var), node2type(Type)}.

tVarName({tvar, _, VarName}) -> VarName;
tVarName(T) -> T.

applyConstraints({'funt',L,Args,RType}, CTMap) ->
    SubstitutedArgs = lists:map(fun(Arg)->
        case maps:is_key(tVarName(Arg), CTMap) of
            true -> maps:get(tVarName(Arg),CTMap);
            false -> applyConstraints(Arg, CTMap)
        end
    end , Args),
    SubstitutedRType = case maps:is_key(tVarName(RType), CTMap) of
        true -> maps:get(tVarName(RType),CTMap);
        false -> applyConstraints(RType, CTMap)
    end,
    hm:funt(SubstitutedArgs, SubstitutedRType, L);
% applyConstraints({tcon, L, "map", {tcon, L_KV,"key-value",KVs}}, CTMap) ->
%     KVs_ = lists:map(fun(Arg)->
%         case maps:is_key(tVarName(Arg), CTMap) of
%             true -> maps:get(tVarName(Arg), CTMap);
%             false -> applyConstraints(Arg, CTMap)
%         end
%     end , KVs),
%     {tcon, L, "map", {tcon,L_KV,"key-value",KVs_}};
applyConstraints({tcon, L, Name, Args}, CTMap) ->
    Args_ = lists:map(fun(Arg)->
        case maps:is_key(tVarName(Arg), CTMap) of
            true -> maps:get(tVarName(Arg), CTMap);
            false -> applyConstraints(Arg, CTMap)
        end
    end , Args),
    {tcon, L, Name, Args_};
applyConstraints(T, _) -> T.

% Hack for recursive type constraints application
applyCtrsToCtrs(CTMap) ->
    lists:foldl(fun({Var, Ty}, NMap) ->
        % ?PRINT(Var),
        % ?PRINT(Ty),
        NT = applyConstraints(Ty, CTMap),
        % ?PRINT(NT),
        maps:put(Var, NT, NMap)
        end
    , maps:new(), maps:to_list(CTMap)).

% given a list branches, add all the common bindings (in all of them) to the env
addCommonBindings(Clauses,Env,L) ->
    CommonBindings = case Clauses of
        [] -> [];
        _  ->
            BindingsList = lists:map(fun erl_syntax_lib:variables/1, Clauses),
            sets:to_list(sets:intersection(BindingsList))
    end,
    lists:foldl(fun(X,AccEnv) ->
        {AccEnv_,_,_} = checkExpr(AccEnv,{var,L,X}), AccEnv_
    end, Env, CommonBindings).

addRec(Node,Env) ->
    addRecUDT(element(4,Node),Env,util:getLn(Node)).

addRecUDT({Constr,Fields},Env,L) ->
    ArgTypes = lists:foldr(fun(F,AccArgs) ->
        case F of
            {record_field,LF,_} -> 
                [hm:fresh(LF)|AccArgs];
            {record_field,LF,_,DefaultValue} ->
                [hm:fresh(LF)|AccArgs];
            {typed_record_field
                , {record_field,_,_}
                , TypeNode} -> 
                [node2type(TypeNode)|AccArgs];
            {typed_record_field
                , {record_field,_,_,_}
                , TypeNode} ->
                [node2type(TypeNode)|AccArgs]
        end
    end, [], Fields),
    TVars = lists:filter(fun hm:isTVar/1,ArgTypes),
    RConstrType = hm:funt(ArgTypes,hm:tcon(Constr,TVars,L),L),
    PolyRConstrType = hm:generalize(RConstrType,Env,[]),
    env:extendRecord(Constr,PolyRConstrType,Fields,Env).

getRecFieldValue(_,[]) ->
    {nothing};
getRecFieldValue(Field,[{record_field,_,{atom,_,Field},Value}|_]) ->
    {just,Value};
getRecFieldValue(Field,[{typed_record_field,{record_field,_,{atom,_,Field}},Value}|_]) ->
    {just,Value};
getRecFieldValue(Field,[_|FVs]) ->
    getRecFieldValue(Field,FVs).

getField({record_field,_,{atom,_,Field}}) -> 
    Field;
getField({record_field,_,{atom,_,Field},_}) ->
    Field;
getField({typed_record_field, {record_field,_,{atom,_,Field},_}, _}) -> 
    Field;
getField({typed_record_field, {record_field,_,{atom,_,Field}}, _}) -> 
    Field.

findFieldType(FieldName, %field name
    [{record_field,_,{atom,_,FieldName}}|_] %field definition
    ,[A|_]) -> %constructor arg type corresponding to field
    A;
findFieldType(FieldName, %field name
    [{record_field,_,{atom,_,FieldName},_}|_] %field definition
    ,[A|_]) -> %constructor arg type corresponding to field
    A;
findFieldType(FieldName,
    [{typed_record_field,{record_field,_,{atom,_,FieldName}},_}|_]
    ,[A|_]) ->
    A;
findFieldType(FieldName,
    [{typed_record_field,{record_field,_,{atom,_,FieldName},_},_}|_]
    ,[A|_]) ->
    A;
findFieldType(FieldName,[_|Fs],[_|As]) ->
    findFieldType(FieldName,Fs,As).

getDefaultValue({record_field,_,{atom,_,_},Value}) ->
    {just,Value};
getDefaultValue({typed_record_field,{record_field,_,{atom,_,_},Value},_}) ->
    {just,Value};
getDefaultValue(T) ->
    {nothing}.

%% Spec parsing
getSpecWithAllFuns(Env, Specs) ->
    SpecFns = lists:map(fun(Spec) -> specToType(Env, element(4, Spec)) end, Specs),
    spec:add_functions(SpecFns, spec:empty()).

specToType(Env, {QFName, Types}) ->
    % {QFName, lists:map(fun node2type/1, Types)}.
    % We have to see how to handle multiple functions
    % ?PRINT(Types),
    SpecT = hd(lists:map(fun node2type/1, Types)),
    InPlaced = hm:inplaceUDT(Env, SpecT),
    RnkNSpec = hm:rankNSpec(InPlaced, sets:new()),
    {QFName, RnkNSpec}.

checkWithSpec(Spec, X, T) ->
    SpecTs = spec:lookup(X, Spec),
    case SpecTs of
        undefined -> [];
         _ ->
        Lines = lists:map(fun(ST) -> integer_to_list(hm:getLn(ST)) end, SpecTs),
        Same = not lists:member(false, lists:map(fun(ST) -> hm:is_same(ST, T) end, SpecTs)),
        case Same of
            true  -> io:fwrite("Same as type spec defined in lines ~p ~n", [Lines]);
            false -> io:fwrite("Different from type defined in lines ~p ~n", [Lines])
        end
    end.


convertUDT(Env, Node) ->
    {TypeConstr,DataConstrs,Args} = element(4, Node),
    L = util:getLn(Node),
    TypeId = {TypeConstr, length(Args)},
    % ?PRINT(TypeConstr),
    % ?PRINT(TypeId),
    % make type constructor
    Type = hm:tcon(TypeConstr,lists:map(fun node2type/1, Args),L),
    CtrType = node2type(DataConstrs),
    % GenType = hm:generalizeSpecT(Env, Type),
    % GenCtrType = hm:generalizeSpecT(Env, CtrType),
    % add every data constructor to Env
    env:extendUDT(TypeId,{Type, CtrType}, Env).
