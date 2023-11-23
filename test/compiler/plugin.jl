module PluginTests
using Test 
const BE = Base.Experimental

BE.@MethodTable(SinCosTable)
BE.@new_plugin(SinCosPlugin, SinCosTable)

BE.@overlay SinCosTable sin(x) = cos(x)

@testset "SinToCosPlugin" begin
    @test BE.invoke_within(SinCosPlugin(), sin, 1.0) == cos(1.0)
end

end
