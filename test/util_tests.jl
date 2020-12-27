using Crux
using Test
using POMDPModels
using Flux
using LinearAlgebra
using CUDA

## Spaces
mdp = SimpleGridWorld()

s1 = DiscreteSpace(5)
@test s1 isa AbstractSpace
@test s1 isa DiscreteSpace
@test s1.N == 5
@test useonehot(s1)
@test type(s1) == Bool
@test dim(s1) == (5,)

s2 = DiscreteSpace(5, false, Symbol)
@test s2 isa AbstractSpace
@test s2 isa DiscreteSpace
@test s2.N == 5
@test !useonehot(s2)
@test type(s2) == Symbol
@test dim(s2) == (1,)

s3 = ContinuousSpace((3,4), Float64)
@test s3 isa AbstractSpace
@test s3 isa ContinuousSpace
@test s3.dims == (3,4)
@test !useonehot(s3)
@test type(s3) == Float64
@test dim(s3) == (3,4)

s4 = state_space(mdp)
@test s4 isa ContinuousSpace
@test dim(s4) == (2,)
@test !useonehot(s4)

## Gpu stuff
vcpu = zeros(Float32, 10, 10)
vgpu = cu(zeros(Float32, 10, 10))
@test Crux.device(vcpu) == cpu
@test Crux.device(vgpu) == gpu
@test Crux.device(view(vcpu,:,1)) == cpu
@test Crux.device(view(vgpu,:,1)) == gpu

c1 = Chain(Dense(5, 5, relu))
c2 = Chain(Dense(5, 5, relu))
c3 = Chain(Dense(5, 5, relu)) |> gpu

@test c1[1].W != c2[1].W
copyto!(c1, c2)

@test c1[1].W == c2[1].W

copyto!(c3, c2)
@test c3[1].W isa CuArray
@test cpu(c3[1].W) == c2[1].W

c_cpu = Chain(Dense(5,2))
c_gpu = Chain(Dense(5,2)) |> gpu
@test Crux.device(c_cpu) == cpu
@test Crux.device(c_gpu) == gpu

@test Crux.device(mdcall(c_cpu, rand(5), cpu)) == cpu
@test Crux.device(mdcall(c_gpu, rand(5), gpu)) == cpu
@test Crux.device(mdcall(c_cpu, cu(rand(5)), cpu)) == gpu
@test Crux.device(mdcall(c_gpu, cu(rand(5)), gpu)) == gpu

v = zeros(4,4,4)
@test size(bslice(v, 2)) == (4,4)

## Flux Stuff
W = rand(2, 5)
b = rand(2)

predict(x) = (W * x) .+ b
loss(x, y) = sum((predict(x) .- y).^2)

x, y = rand(5), rand(2) # Dummy data
l = loss(x, y) # ~ 3

θ = Flux.params(W, b)
grads = Flux.gradient(() -> loss(x, y), θ)

@test norm(grads) > 2






