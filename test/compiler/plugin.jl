module PluginTests

const CC = Core.Compiler

struct SinCosPlugin <: CC.CompilerPlugin
end

Base.Experimental.@MethodTable(SinCosTable)
Base.Experimental.@overlay SinCosTable sin(x) = cos(x)

import Core: MethodInstance, CodeInstance
import .CC: WorldRange, WorldView

struct SinCosRewriterCache
    dict::IdDict{MethodInstance,CodeInstance}
end

struct SinCosRewriter <: CC.AbstractInterpreter
    interp::CC.NativeInterpreter
    world::UInt
    cache::SinCosRewriterCache
end

let global_cache = SinCosRewriterCache(IdDict{MethodInstance,CodeInstance}())
    global function SinCosRewriter(
        world = Base.get_world_counter();
        interp = CC.NativeInterpreter(world),
        cache = global_cache)
        return SinCosRewriter(interp, world, cache)
    end
end
CC.abstract_interpreter(::SinCosPlugin, world) = SinCosRewriter(world)

CC.InferenceParams(interp::SinCosRewriter) = CC.InferenceParams(interp.interp)
CC.OptimizationParams(interp::SinCosRewriter) = CC.OptimizationParams(interp.interp)
CC.get_world_counter(interp::SinCosRewriter) = CC.get_world_counter(interp.interp)
CC.get_inference_cache(interp::SinCosRewriter) = CC.get_inference_cache(interp.interp)
CC.code_cache(interp::SinCosRewriter) = WorldView(interp.cache, WorldRange(CC.get_world_counter(interp)))
CC.get(wvc::WorldView{<:SinCosRewriterCache}, mi::MethodInstance, default) = get(wvc.cache.dict, mi, default)
CC.getindex(wvc::WorldView{<:SinCosRewriterCache}, mi::MethodInstance) = getindex(wvc.cache.dict, mi)
CC.haskey(wvc::WorldView{<:SinCosRewriterCache}, mi::MethodInstance) = haskey(wvc.cache.dict, mi)
function CC.setindex!(wvc::WorldView{<:SinCosRewriterCache}, ci::CodeInstance, mi::MethodInstance)
    # ccall(:jl_mi_cache_insert, Cvoid, (Any, Any), mi, ci)
    setindex!(wvc.cache.dict, ci, mi)
end
CC.method_table(interp::SinCosRewriter) = CC.OverlayMethodTable(interp.interp.world, SinCosTable)

@testset "SinToCosPlugin" begin
    @test CC.invoke_within(SinCosPlugin(), sin, 1.0) == cos(1.0)
end

end
