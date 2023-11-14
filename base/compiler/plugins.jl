abstract type CompilerPlugin end

struct NativeCompilerPlugin <: CompilerPlugin end

"""
    abstract_interpreter(::CompilerPlugin, world)

Construct an [`AbstractInterpreter`](@ref) for this compiler plugin.
"""
function abstract_interpreter end

abstract_interpreter(::NativeCompilerPlugin, world) = NativeInterpreter(world)

"""
    invoke_within(::CompilerPlugin, f, args...)

Call function `f` with arguments `args` within the context of
a different compiler plugin.
"""
function invoke_within(C::CompilerPlugin, f, args...)
    tunnel = wormhole(C, f, args...)::OpaqueClosure
    # TODO: Implement dynamically scoped semantics for compiler plugin
    # current_compiler = current_task().compiler
    # current_task().compiler = C # We have now switched dynamic compiler contexts
    try
        return tunnel(args...) # Execute tunnel within new dynamic context
    finally
        # current_task().compiler = current_compiler
    end
end

function wormhole(C::CompilerPlugin, f, args...)::OpaqueClosure
    @nospecialize f args
    interp = abstract_interpreter(C, get_world_counter())
    
    tt = signature_type(f, Tuple{map(Typeof, args)...})
    mt = method_table(interp)
    match, valid_worlds, overlayed = findsup(tt, mt)

    if match === nothing
        error("Unable to find matching $tt")
    end
    mi = specialize_method(match.method, match.spec_types, match.sparams)::MethodInstance
    code = get(code_cache(interp), mi, nothing)
    if code !== nothing
        inf = code.inferred
        ci = Base._uncompressed_ir(code, inf)
        return OpaqueClosure(ci)
    end
    result = InferenceResult(mi)
    frame = InferenceState(result, #=cache=# :global, interp)
    typeinf(interp, frame)
    ci = frame.src
    return OpaqueClosure(ci)
end
