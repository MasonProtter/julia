# This file is a part of Julia. License is MIT: https://julialang.org/license

# make sure that typeinf is executed before turning on typeinf_ext
# this ensures that typeinf_ext doesn't recurse before it can add the item to the workq
# especially try to make sure any recursive and leaf functions have concrete signatures,
# since we won't be able to specialize & infer them at runtime

activate_codegen!() = ccall(:jl_set_typeinf_func, Cvoid, (Any,), typeinf_ext_toplevel)

function bootstrap!()
    let time() = ccall(:jl_clock_now, Float64, ())
        println("Compiling the compiler. This may take several minutes ...")
        interp = NativeInterpreter()

        # analyze_escapes_tt = Tuple{typeof(analyze_escapes), IRCode, Int, TODO}
        optimize_tt = Tuple{typeof(optimize), NativeInterpreter, OptimizationState{NativeInterpreter}, InferenceResult}
        fs = Any[
            # we first create caches for the optimizer, because they contain many loop constructions
            # and they're better to not run in interpreter even during bootstrapping
            #=analyze_escapes_tt,=# optimize_tt,
            # then we create caches for inference entries
            typeinf_ext, typeinf, typeinf_edge,
        ]
        # tfuncs can't be inferred from the inference entries above, so here we infer them manually
        for x in T_FFUNC_VAL
            push!(fs, x[3])
        end
        for i = 1:length(T_IFUNC)
            if isassigned(T_IFUNC, i)
                x = T_IFUNC[i]
                push!(fs, x[3])
            else
                println(stderr, "WARNING: tfunc missing for ", reinterpret(IntrinsicFunction, Int32(i)))
            end
        end
        starttime = time()
        for f in fs
            if isa(f, DataType) && f.name === typename(Tuple)
                tt = f
            else
                tt = Tuple{typeof(f), Vararg{Any}}
            end
            for m in _methods_by_ftype(tt, 10, get_world_counter())::Vector
                # remove any TypeVars from the intersection
                m = m::MethodMatch
                typ = Any[m.spec_types.parameters...]
                for i = 1:length(typ)
                    typ[i] = unwraptv(typ[i])
                end
                typeinf_type(interp, m.method, Tuple{typ...}, m.sparams)
            end
        end
        endtime = time()
        println("Base.Compiler ──── ", sub_float(endtime,starttime), " seconds")
    end
    activate_codegen!()
end

function activate!(; reflection=true, codegen=false)
    if reflection
        Base.REFLECTION_COMPILER[] = Compiler
    end
    if codegen
        activate_codegen!()
    end
end