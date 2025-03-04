"""
```julia
vectorized_solve(probs, prob::Union{ODEProblem, SDEProblem}alg;
                 dt, saveat = nothing,
                 save_everystep = true,
                 debug = false, callback = CallbackSet(nothing), tstops = nothing)
```

A lower level interface to the kernel generation solvers of EnsembleGPUKernel.

## Arguments

  - `probs`: the GPU-setup problems generated by the ensemble.
  - `prob`: the quintessential problem form. Can be just `probs[1]`
  - `alg`: the kernel-based differential equation solver. Must be one of the
    EnsembleGPUKernel specialized methods.

## Keyword Arguments

Only a subset of the common solver arguments are supported.
"""
function vectorized_solve end

function vectorized_solve(probs, prob::ODEProblem, alg;
                          dt, saveat = nothing,
                          save_everystep = true,
                          debug = false, callback = CallbackSet(nothing), tstops = nothing,
                          kwargs...)
    dev = get_device(probs)
    dev = maybe_prefer_blocks(dev)
    # if saveat is specified, we'll use a vector of timestamps.
    # otherwise it's a matrix that may be different for each ODE.
    timeseries = prob.tspan[1]:dt:prob.tspan[2]
    nsteps = length(timeseries)

    if saveat === nothing
        if save_everystep
            len = length(prob.tspan[1]:dt:prob.tspan[2])
            if tstops !== nothing
                len += length(tstops) - count(x -> x in tstops, timeseries)
                nsteps += length(tstops) - count(x -> x in tstops, timeseries)
            end
        else
            len = 2
        end
        ts = allocate(dev, typeof(dt), (len, length(probs)))
        fill!(ts, prob.tspan[1])
        us = allocate(dev, typeof(prob.u0), (len, length(probs)))
    else
        saveat = adapt(dev, saveat)
        ts = allocate(dev, typeof(dt), (length(saveat), length(probs)))
        fill!(ts, prob.tspan[1])
        us = allocate(dev, typeof(prob.u0), (length(saveat), length(probs)))
    end

    tstops = adapt(dev, tstops)

    if alg isa GPUTsit5
        kernel = tsit5_kernel(dev)
    elseif alg isa GPUVern7
        kernel = vern7_kernel(dev)
    elseif alg isa GPUVern9
        kernel = vern9_kernel(dev)
    end

    if dev isa CPU
        @warn "Running the kernel on CPU"
    end

    event = kernel(probs, us, ts, dt, callback, tstops, nsteps, saveat, Val(save_everystep);
                   ndrange = length(probs), dependencies = Event(dev))
    wait(dev, event)

    # we build the actual solution object on the CPU because the GPU would create one
    # containig CuDeviceArrays, which we cannot use on the host (not GC tracked,
    # no useful operations, etc). That's unfortunate though, since this loop is
    # generally slower than the entire GPU execution, and necessitates synchronization
    #EDIT: Done when using with DiffEqGPU
    ts, us
end

# SDEProblems over GPU cannot support u0 as a Number type, because GPU kernels compiled only through u0 being StaticArrays
function vectorized_solve(probs, prob::SDEProblem, alg;
                          dt, saveat = nothing,
                          save_everystep = true,
                          debug = false,
                          kwargs...)
    dev = get_device(probs)
    dev = maybe_prefer_blocks(dev)
    if saveat === nothing
        if save_everystep
            len = length(prob.tspan[1]:dt:prob.tspan[2])
        else
            len = 2
        end
        ts = allocate(dev, typeof(dt), (len, length(probs)))
        fill!(ts, prob.tspan[1])
        us = allocate(dev, typeof(prob.u0), (len, length(probs)))
    else
        saveat = adapt(dev, saveat)
        ts = allocate(dev, typeof(dt), (length(saveat), length(probs)))
        fill!(ts, prob.tspan[1])
        us = allocate(dev, typeof(prob.u0), (length(saveat), length(probs)))
    end

    if alg isa GPUEM
        kernel = em_kernel(dev)
    elseif alg isa Union{GPUSIEA}
        SciMLBase.is_diagonal_noise(prob) ? nothing :
        error("The algorithm is not compatible with the chosen noise type. Please see the documentation on the solver methods")
        kernel = siea_kernel(dev)
    end

    if dev isa CPU
        @warn "Running the kernel on CPU"
    end

    event = kernel(probs, us, ts, dt, saveat, Val(save_everystep);
                   ndrange = length(probs), dependencies = Event(dev))
    wait(dev, event)

    ts, us
end

function vectorized_asolve(probs, prob::ODEProblem, alg;
                           dt = 0.1f0, saveat = nothing,
                           save_everystep = false,
                           abstol = 1.0f-6, reltol = 1.0f-3,
                           debug = false, callback = CallbackSet(nothing), tstops = nothing,
                           kwargs...)
    dev = get_device(probs)
    dev = maybe_prefer_blocks(dev)
    # if saveat is specified, we'll use a vector of timestamps.
    # otherwise it's a matrix that may be different for each ODE.
    if saveat === nothing
        if save_everystep
            error("Don't use adaptive version with saveat == nothing and save_everystep = true")
        else
            len = 2
        end
        # if tstops !== nothing
        #     len += length(tstops)
        # end
        ts = allocate(dev, typeof(dt), (len, length(probs)))
        fill!(ts, prob.tspan[1])
        us = allocate(dev, typeof(prob.u0), (len, length(probs)))
    else
        saveat = adapt(dev, saveat)
        ts = allocate(dev, typeof(dt), (length(saveat), length(probs)))
        fill!(ts, prob.tspan[1])
        us = allocate(dev, typeof(prob.u0), (length(saveat), length(probs)))
    end

    us = adapt(dev, us)
    ts = adapt(dev, ts)
    tstops = adapt(dev, tstops)

    if alg isa GPUTsit5
        kernel = atsit5_kernel(dev)
    elseif alg isa GPUVern7
        kernel = avern7_kernel(dev)
    elseif alg isa GPUVern9
        kernel = avern9_kernel(dev)
    end

    if dev isa CPU
        @warn "Running the kernel on CPU"
    end

    event = kernel(probs, us, ts, dt, callback, tstops,
                   abstol, reltol, saveat, Val(save_everystep);
                   ndrange = length(probs), dependencies = Event(dev))
    wait(dev, event)

    # we build the actual solution object on the CPU because the GPU would create one
    # containig CuDeviceArrays, which we cannot use on the host (not GC tracked,
    # no useful operations, etc). That's unfortunate though, since this loop is
    # generally slower than the entire GPU execution, and necessitates synchronization
    #EDIT: Done when using with DiffEqGPU
    ts, us
end

function vectorized_asolve(probs, prob::SDEProblem, alg;
                           dt, saveat = nothing,
                           save_everystep = true,
                           debug = false,
                           kwargs...)
    error("Adaptive time-stepping is not supported yet with GPUEM.")
end
