abstract type CompilerPlugin end

# struct NativeCompilerPlugin <: CompilerPlugin end
# We use `nothing` as the tag value for the NativeCompilerPlugin.
NativeCompilerPlugin() = nothing

# Notes:
# - CompilerPlugins are used as tags for CodeInstances,
#   we thus need to make the "unique" similar to MethodInstances
# - Instead of CompilerPlugins maybe a better name is CompilerInstances
# - How do we deal with nesting?

"""
    abstract_interpreter(::CompilerPlugin, world)

Construct an [`AbstractInterpreter`](@ref) for this compiler plugin.
"""
function abstract_interpreter end

abstract_interpreter(::Nothing, world) = NativeInterpreter(world)


isplugin(interp) = false
function get_plugin_gref end


"""
    invoke_within(::CompilerPlugin, f, args...)

Call function `f` with arguments `args` within the context of
a different compiler plugin.
"""
function invoke_within(C::Union{Nothing, CompilerPlugin}, f, args...)
    tunnel = wormhole(C, f, args...)::Core.OpaqueClosure
    the_task = ccall(:jl_get_current_task, Ref{Task}, ())
    
    current_compilerplugin = the_task.compilerplugin
    the_task.compilerplugin = C # We have now switched dynamic compiler contexts
    try
        return tunnel(args...) # Execute tunnel within new dynamic context
    finally
        the_task.compilerplugin = current_compilerplugin
    end
end

function code_plugin(C::Union{Nothing, CompilerPlugin}, f, args...)
    @nospecialize f args
    interp = abstract_interpreter(C, get_world_counter())
    
    tt = signature_type(f, Tuple{map(Core.Typeof, args)...})
    mt = method_table(interp)
    match, _ = findsup(tt, mt)

    if match === nothing
        error("Unable to find matching $tt")
    end
    mi = specialize_method(match.method, match.spec_types, match.sparams)::MethodInstance
    code = get(code_cache(interp), mi, nothing)
    if code !== nothing
        inf = code.inferred
        ci = _uncompressed_ir(code, inf)
        return ci
    end
    result = InferenceResult(mi)
    frame = InferenceState(result, #=cache=# :global, interp)
    typeinf(interp, frame)
    ci = frame.src
    return ci
end 

function wormhole(C::Union{Nothing, CompilerPlugin}, f, args...)::Core.OpaqueClosure
    Core.OpaqueClosure(code_plugin(C, f, args...))
end
                     
"""
    struct CompilerPluginCodeCache

Internally, each `MethodInstance` keep a unique global cache of code instances
that have been created for the given method instance, stratified by world age
ranges. This struct abstracts over access to this cache.
"""
struct CompilerPluginCodeCache
    compilerplugin::Union{Nothing,CompilerPlugin}
end

function setindex!(cache::CompilerPluginCodeCache, ci::CodeInstance, mi::MethodInstance)
    @assert ci.compilerplugin == cache.compilerplugin
    ccall(:jl_mi_cache_insert, Cvoid, (Any, Any), mi, ci)
    return cache
end

function haskey(wvc::WorldView{CompilerPluginCodeCache}, mi::MethodInstance)
    return ccall(:jl_rettype_inferred_within, Any, (Any, UInt, UInt, Any), mi, first(wvc.worlds), last(wvc.worlds), wvc.cache.compilerplugin) !== nothing
end

function get(wvc::WorldView{CompilerPluginCodeCache}, mi::MethodInstance, default)
    r = ccall(:jl_rettype_inferred_within, Any, (Any, UInt, UInt, Any), mi, first(wvc.worlds), last(wvc.worlds), wvc.cache.compilerplugin)
    if r === nothing
        return default
    end
    return r::CodeInstance
end
