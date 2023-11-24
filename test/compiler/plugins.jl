module PluginTests
using Test 
const BE = Base.Experimental

BE.@MethodTable(SinCosTable)
BE.@new_plugin(SinCosPlugin, SinCosTable)

BE.@overlay SinCosTable sin(x) = cos(x)

@noinline g(x) = sin(x[])

@testset "SinToCosPlugin" begin
    @test SinCosPlugin(sin, 1.0) == cos(1.0)
 
    @test cos(1.0) == SinCosPlugin(Ref{Any}(1.0)) do r
        g(r)
    end
end

end
