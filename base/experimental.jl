# This file is a part of Julia. License is MIT: https://julialang.org/license

"""
    Experimental

!!! warning
    Types, methods, or macros defined in this module are experimental and subject
    to change and will not have deprecations. Caveat emptor.
"""
module Experimental

using Base: Threads, sync_varname, is_function_def, @propagate_inbounds
using Base.Meta

"""
    Const(A::Array)

Mark an Array as constant/read-only. The invariant guaranteed is that you will not
modify an Array (through another reference) within an `@aliasscope` scope.

!!! warning
    Experimental API. Subject to change without deprecation.
"""
struct Const{T,N} <: DenseArray{T,N}
    a::Array{T,N}
end

Base.IndexStyle(::Type{<:Const}) = IndexLinear()
Base.size(C::Const) = size(C.a)
Base.axes(C::Const) = axes(C.a)
@propagate_inbounds Base.getindex(A::Const, i1::Int, I::Int...) = A.a[i1, I...]

"""
    @aliasscope expr

Allows the compiler to assume that all `Const`s are not being modified through stores
within this scope, even if the compiler can't prove this to be the case.

!!! warning
    Experimental API. Subject to change without deprecation.
"""
macro aliasscope(body)
    sym = gensym()
    quote
        $(Expr(:aliasscope))
        $sym = $(esc(body))
        $(Expr(:popaliasscope))
        $sym
    end
end


function sync_end(c::Channel{Any})
    if !isready(c)
        # there must be at least one item to begin with
        close(c)
        return
    end
    nremaining::Int = 0
    while true
        event = take!(c)
        if event === :__completion__
            nremaining -= 1
            if nremaining == 0
                break
            end
        else
            nremaining += 1
            schedule(Task(()->begin
                try
                    wait(event)
                    put!(c, :__completion__)
                catch e
                    close(c, e)
                end
            end))
        end
    end
    close(c)
    nothing
end

"""
    Experimental.@sync

Wait until all lexically-enclosed uses of [`@async`](@ref), [`@spawn`](@ref Threads.@spawn),
`Distributed.@spawnat` and `Distributed.@distributed`
are complete, or at least one of them has errored. The first exception is immediately
rethrown. It is the responsibility of the user to cancel any still-running operations
during error handling.

!!! Note
    This is different to [`@sync`](@ref) in that errors from wrapped tasks are thrown immediately,
    potentially before all tasks have returned.

!!! Note
    This interface is experimental and subject to change or removal without notice.
"""
macro sync(block)
    var = esc(sync_varname)
    quote
        let $var = Channel(Inf)
            v = $(esc(block))
            sync_end($var)
            v
        end
    end
end

"""
    Experimental.@optlevel n::Int

Set the optimization level (equivalent to the `-O` command line argument)
for code in the current module. Submodules inherit the setting of their
parent module.

Supported values are 0, 1, 2, and 3.

The effective optimization level is the minimum of that specified on the
command line and in per-module settings. If a `--min-optlevel` value is
set on the command line, that is enforced as a lower bound.
"""
macro optlevel(n::Int)
    return Expr(:meta, :optlevel, n)
end

"""
    Experimental.@max_methods n::Int

Set the maximum number of potentially-matching methods considered when running inference
for methods defined in the current module. This setting affects inference of calls with
incomplete knowledge of the argument types.

The benefit of this setting is to avoid excessive compilation and reduce invalidation risks
in poorly-inferred cases. For example, when `@max_methods 2` is set and there are two
potentially-matching methods returning different types inside a function body, then Julia
will compile subsequent calls for both types so that the compiled function body accounts
for both possibilities. Also the compiled code is vulnerable to invalidations that would
happen when either of the two methods gets invalidated. This speculative compilation and
these invalidations can be avoided by setting `@max_methods 1` and allowing the compiled
code to resort to runtime dispatch instead.

Supported values are `1`, `2`, `3`, `4`, and `default` (currently equivalent to `3`).
"""
macro max_methods(n::Int)
    1 <= n <= 4 || error("We must have that `1 <= max_methods <= 4`, but `max_methods = $n`.")
    return Expr(:meta, :max_methods, n)
end

"""
    Experimental.@max_methods n::Int function fname end

Set the maximum number of potentially-matching methods considered when running inference
for the generic function `fname`. Overrides any module-level or global inference settings
for max_methods. This setting is global for the entire generic function (or more precisely
the MethodTable).
"""
macro max_methods(n::Int, fdef::Expr)
    1 <= n <= 255 || error("We must have that `1 <= max_methods <= 255`, but `max_methods = $n`.")
    (fdef.head === :function && length(fdef.args) == 1) || error("Second argument must be a function forward declaration")
    return :(typeof($(esc(fdef))).name.max_methods = $(UInt8(n)))
end

"""
    Experimental.@compiler_options optimize={0,1,2,3} compile={yes,no,all,min} infer={yes,no} max_methods={default,1,2,3,4}

Set compiler options for code in the enclosing module. Options correspond directly to
command-line options with the same name, where applicable. The following options
are currently supported:

  * `optimize`: Set optimization level.
  * `compile`: Toggle native code compilation. Currently only `min` is supported, which
    requests the minimum possible amount of compilation.
  * `infer`: Enable or disable type inference. If disabled, implies [`@nospecialize`](@ref).
  * `max_methods`: Maximum number of matching methods considered when running type inference.
"""
macro compiler_options(args...)
    opts = Expr(:block)
    for ex in args
        if isa(ex, Expr) && ex.head === :(=) && length(ex.args) == 2
            if ex.args[1] === :optimize
                push!(opts.args, Expr(:meta, :optlevel, ex.args[2]::Int))
            elseif ex.args[1] === :compile
                a = ex.args[2]
                a = #a === :no  ? 0 :
                    #a === :yes ? 1 :
                    #a === :all ? 2 :
                    a === :min ? 3 : error("invalid argument to \"compile\" option")
                push!(opts.args, Expr(:meta, :compile, a))
            elseif ex.args[1] === :infer
                a = ex.args[2]
                a = a === false || a === :no  ? 0 :
                    a === true  || a === :yes ? 1 : error("invalid argument to \"infer\" option")
                push!(opts.args, Expr(:meta, :infer, a))
            elseif ex.args[1] === :max_methods
                a = ex.args[2]
                a = a === :default ? 3 :
                  a isa Int ? ((1 <= a <= 4) ? a : error("We must have that `1 <= max_methods <= 4`, but `max_methods = $a`.")) :
                  error("invalid argument to \"max_methods\" option")
                push!(opts.args, Expr(:meta, :max_methods, a))
            else
                error("unknown option \"$(ex.args[1])\"")
            end
        else
            error("invalid option syntax")
        end
    end
    return opts
end

"""
    Experimental.@force_compile

Force compilation of the block or function (Julia's built-in interpreter is blocked from executing it).

# Examples

```
julia> occursin("interpreter", string(stacktrace(begin
           # with forced compilation
           Base.Experimental.@force_compile
           backtrace()
       end, true)))
false

julia> occursin("interpreter", string(stacktrace(begin
           # without forced compilation
           backtrace()
       end, true)))
true
```
"""
macro force_compile() Expr(:meta, :force_compile) end

# UI features for errors

"""
    Experimental.register_error_hint(handler, exceptiontype)

Register a "hinting" function `handler(io, exception)` that can
suggest potential ways for users to circumvent errors.  `handler`
should examine `exception` to see whether the conditions appropriate
for a hint are met, and if so generate output to `io`.
Packages should call `register_error_hint` from within their
`__init__` function.

For specific exception types, `handler` is required to accept additional arguments:

- `MethodError`: provide `handler(io, exc::MethodError, argtypes, kwargs)`,
  which splits the combined arguments into positional and keyword arguments.

When issuing a hint, the output should typically start with `\\n`.

If you define custom exception types, your `showerror` method can
support hints by calling [`Experimental.show_error_hints`](@ref).

# Example

```
julia> module Hinter

       only_int(x::Int)      = 1
       any_number(x::Number) = 2

       function __init__()
           Base.Experimental.register_error_hint(MethodError) do io, exc, argtypes, kwargs
               if exc.f == only_int
                    # Color is not necessary, this is just to show it's possible.
                    print(io, "\\nDid you mean to call ")
                    printstyled(io, "`any_number`?", color=:cyan)
               end
           end
       end

       end
```

Then if you call `Hinter.only_int` on something that isn't an `Int` (thereby triggering a `MethodError`), it issues the hint:

```
julia> Hinter.only_int(1.0)
ERROR: MethodError: no method matching only_int(::Float64)
Did you mean to call `any_number`?
Closest candidates are:
    ...
```

!!! compat "Julia 1.5"
    Custom error hints are available as of Julia 1.5.
!!! warning
    This interface is experimental and subject to change or removal without notice.
    To insulate yourself against changes, consider putting any registrations inside an
    `if isdefined(Base.Experimental, :register_error_hint) ... end` block.
"""
function register_error_hint(@nospecialize(handler), @nospecialize(exct::Type))
    list = get!(Vector{Any}, _hint_handlers, exct)
    push!(list, handler)
    return nothing
end

const _hint_handlers = IdDict{Type,Vector{Any}}()

"""
    Experimental.show_error_hints(io, ex, args...)

Invoke all handlers from [`Experimental.register_error_hint`](@ref) for the particular
exception type `typeof(ex)`. `args` must contain any other arguments expected by
the handler for that type.

!!! compat "Julia 1.5"
    Custom error hints are available as of Julia 1.5.
!!! warning
    This interface is experimental and subject to change or removal without notice.
"""
function show_error_hints(io, ex, args...)
    hinters = get(_hint_handlers, typeof(ex), nothing)
    isnothing(hinters) && return
    for handler in hinters
        try
            Base.invokelatest(handler, io, ex, args...)
        catch err
            tn = typeof(handler).name
            @error "Hint-handler $handler for $(typeof(ex)) in $(tn.module) caused an error"
        end
    end
end

# OpaqueClosure
include("opaque_closure.jl")

"""
    Experimental.@overlay mt [function def]

Define a method and add it to the method table `mt` instead of to the global method table.
This can be used to implement a method override mechanism. Regular compilation will not
consider these methods, and you should customize the compilation flow to look in these
method tables (e.g., using [`Core.Compiler.OverlayMethodTable`](@ref)).
"""
macro overlay(mt, def)
    def = macroexpand(__module__, def) # to expand @inline, @generated, etc
    is_function_def(def) || error("@overlay requires a function definition")
    return esc(overlay_def!(mt, def))
end

function overlay_def!(mt, @nospecialize ex)
    arg1 = ex.args[1]
    if isexpr(arg1, :call)
        arg1.args[1] = Expr(:overlay, mt, arg1.args[1])
    elseif isexpr(arg1, :(::))
        overlay_def!(mt, arg1)
    elseif isexpr(arg1, :where)
        overlay_def!(mt, arg1)
    else
        error("@overlay requires a function definition")
    end
    return ex
end

let new_mt(name::Symbol, mod::Module) = begin
        ccall(:jl_check_top_level_effect, Cvoid, (Any, Cstring), mod, "@MethodTable")
        ccall(:jl_new_method_table, Any, (Any, Any), name, mod)
    end
    @eval macro MethodTable(name::Symbol)
        esc(:(const $name = $$new_mt($(quot(name)), $(__module__))))
    end
end

"""
    Experimental.@MethodTable(name)

Create a new MethodTable in the current module, bound to `name`. This method table can be
used with the [`Experimental.@overlay`](@ref) macro to define methods for a function without
adding them to the global method table.
"""
:@MethodTable

"""
    Experimental.@new_plugin(PluginName, method_table=nothing)

Create a new compiler plugin whose name is `PluginName` and an accompanying abstract
interpreter `PluginNameInterpreter`. If a second argument is supplied, that argument
gets registered as the overlay method table for the plugin.
"""
macro new_plugin(PluginName, method_table=nothing)
    InterpName = Symbol(PluginName, :Interpreter)
    InterpCacheName = esc(Symbol(InterpName, :Cache))
    InterpName = esc(InterpName)
    PluginName = esc(PluginName)
    C = Core
    CC = Core.Compiler

    method_table_ex = if !isnothing(method_table)
        :($CC.method_table(interp::$InterpName) = $CC.OverlayMethodTable($CC.get_world_counter(interp), $(esc(method_table))))
    end
    
    quote
        struct $InterpCacheName
            dict::IdDict{$C.MethodInstance,$C.CodeInstance}
        end
        $InterpCacheName() = $InterpCacheName(IdDict{$C.MethodInstance,$C.CodeInstance}())
        struct $InterpName <: $CC.AbstractInterpreter
            meta # additional information
            world::UInt
            inf_params::$CC.InferenceParams
            opt_params::$CC.OptimizationParams
            inf_cache::Vector{$CC.InferenceResult}
            code_cache::$InterpCacheName
            function $InterpName(meta = nothing;
                                 world::UInt = Base.get_world_counter(),
                                 inf_params::$CC.InferenceParams = $CC.InferenceParams(),
                                 opt_params::$CC.OptimizationParams = $CC.OptimizationParams(),
                                 inf_cache::Vector{$CC.InferenceResult} = $CC.InferenceResult[],
                                 code_cache::$InterpCacheName = $InterpCacheName())
                return new(meta, world, inf_params, opt_params, inf_cache, code_cache)
            end
        end
        $CC.InferenceParams(interp::$InterpName) = interp.inf_params
        $CC.OptimizationParams(interp::$InterpName) = interp.opt_params
        $CC.get_world_counter(interp::$InterpName) = interp.world
        $CC.get_inference_cache(interp::$InterpName) = interp.inf_cache
        $CC.code_cache(interp::$InterpName) = $CC.WorldView(interp.code_cache, $CC.WorldRange(interp.world))
        $CC.get(wvc::$CC.WorldView{$InterpCacheName}, mi::$C.MethodInstance, default) = $get(wvc.cache.dict, mi, default)
        $CC.getindex(wvc::$CC.WorldView{$InterpCacheName}, mi::$C.MethodInstance) = $getindex(wvc.cache.dict, mi)
        $CC.haskey(wvc::$CC.WorldView{$InterpCacheName}, mi::$C.MethodInstance) = $haskey(wvc.cache.dict, mi)
        $CC.setindex!(wvc::$CC.WorldView{$InterpCacheName}, ci::$C.CodeInstance, mi::$C.MethodInstance) = $setindex!(wvc.cache.dict, ci, mi)
        
        struct $PluginName <: $CC.CompilerPlugin end
        $CC.abstract_interpreter(::$PluginName, world) = $InterpName(; world)
        $method_table_ex
    end
end

"""
    invoke_within(::Core.Compiler.CompilerPlugin, f, args...)

Call function `f` with arguments `args` within the context of
a different compiler plugin.
"""
invoke_within(C::Union{Nothing, Core.Compiler.CompilerPlugin}, f, args...) = Core.Compiler.invoke_within(args...)


end
