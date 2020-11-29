@with_kw mutable struct DQNGAILSolver <: Solver 
    π::DQNPolicy
    D::DQNPolicy
    sdim::Int
    adim::Int = length(π.actions)
    N::Int = 1000
    buffer::ExperienceBuffer = ExperienceBuffer(sdim, adim, 1000)
    expert_buffer::ExperienceBuffer
    nda_buffer::Union{Nothing, ExperienceBuffer} = nothing
    λ_nda::Float32 = 0.5f0
    rng::AbstractRNG = Random.GLOBAL_RNG
    exploration_policy::ExplorationPolicy = EpsGreedyPolicy(LinearDecaySchedule(start=1., stop=0.1, steps=N/2), rng, π.actions)
    L::Function = Flux.Losses.huber_loss
    opt = ADAM(1e-3)
    optD = deepcopy(opt)
    batch_size::Int = 32
    max_steps::Int = 100 
    buffer_init::Int = max(batch_size, 200)
    Δtarget_update::Int = 500
    Δtrain::Int = 4 
    log = LoggerParams(dir = "log/gail", period = 10)
    device = device(π)
    i::Int64 = 1
end

const LBCE = Flux.Losses.logitbinarycrossentropy

dqngail_target(Q, D, 𝒟, γ::Float32) = q_predicted(D, 𝒟) .+ γ .* (1.f0 .- 𝒟[:done]) .* maximum(Q(𝒟[:sp]), dims=1)

function Lᴰ(D, 𝒟_expert::ExperienceBuffer, 𝒟_π::ExperienceBuffer, 𝒟_nda::Union{Nothing, ExperienceBuffer}, λ_nda::Float32)
    L_e, L_π = LBCE(q_predicted(D, 𝒟_expert), 1.f0), LBCE(q_predicted(D, 𝒟_π), 0.f0)
    isnothing(𝒟_nda) ? L_e + L_π : L_e + λ_nda*L_π + (1.f0 - λ_nda)*LBCE(q_predicted(D, 𝒟_nda), 0.f0)
end

function POMDPs.solve(𝒮::DQNGAILSolver, mdp)
    # Log the pre-train performance
    𝒮.i == 0 && log(𝒮.log, 𝒮.i, log_discounted_return(mdp, 𝒮.π, 𝒮.rng))
    
    # Initialize minibatch buffers and sampler
    𝒟_π = ExperienceBuffer(𝒮.sdim, 𝒮.adim, 𝒮.batch_size, device = 𝒮.device)
    𝒟_expert = deepcopy(𝒟_π)
    𝒟_nda = isnothing(𝒮.nda_buffer) ? nothing : deepcopy(𝒟_π)
    γ = Float32(discount(mdp))
    s = Sampler(mdp, 𝒮.π, max_steps = 𝒮.max_steps, exploration_policy = 𝒮.exploration_policy, rng = 𝒮.rng)
    
    # Fill the buffer as needed
    𝒮.i += fillto!(𝒮.buffer, s, 𝒮.buffer_init, i = 𝒮.i)
    
    for 𝒮.i = range(𝒮.i, stop = 𝒮.i + 𝒮.N - 𝒮.Δtrain, step = 𝒮.Δtrain)
        # Take Δtrain steps in the environment
        push!(𝒮.buffer, steps!(s, i = 𝒮.i, Nsteps = 𝒮.Δtrain))
        
        # Sample a minibatch
        rand!(𝒮.rng, 𝒟_π, 𝒮.buffer, i = 𝒮.i)
        rand!(𝒮.rng, 𝒟_expert, 𝒮.expert_buffer, i = 𝒮.i)
        !isnothing(𝒮.nda_buffer) && rand!(𝒮.rng, 𝒟_nda, 𝒮.nda_buffer, i = 𝒮.i)
        
        # train the discrimnator
        lossD, gradD = train!(𝒮.D, () -> Lᴰ(𝒮.D, 𝒟_expert, 𝒟_π, 𝒟_nda, 𝒮.λ_nda), 𝒮.optD, 𝒮.device)
        
        # Compute target, update priorities, and train the generator.
        y = dqngail_target(𝒮.π.Q⁻, 𝒮.D.Q⁻, 𝒟_π, γ)
        prioritized(𝒮.buffer) && update_priorities!(𝒮.buffer, 𝒟_π.indices, td_error(𝒮.π, 𝒟_π, y))
        lossG, gradG = train!(𝒮.π, () -> td_loss(𝒮.π, 𝒟_π, y, 𝒮.L), 𝒮.opt, 𝒮.device)
        
        # Update target network
        elapsed(𝒮.i + 1:𝒮.i + 𝒮.Δtrain, 𝒮.Δtarget_update) && begin copyto!(𝒮.π.Q⁻, 𝒮.π.Q); copyto!(𝒮.D.Q⁻, 𝒮.D.Q) end
        
        # Log results
        log(𝒮.log, 𝒮.i + 1:𝒮.i + 𝒮.Δtrain, log_discounted_return(mdp, 𝒮.π, 𝒮.rng), 
                                            log_loss(lossG, suffix = "G"),
                                            log_loss(lossD, suffix = "D"),
                                            log_gradient(gradG, suffix = "G"),
                                            log_gradient(gradD, suffix = "D"),
                                            log_exploration(𝒮.exploration_policy, 𝒮.i))
    end
    𝒮.i += 𝒮.Δtrain
    𝒮.π
end
