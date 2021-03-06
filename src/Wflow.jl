module Wflow

using Dates
using TOML
using LightGraphs
using NCDatasets
using StaticArrays
using Statistics
using UnPack
using CSV
using Random
using DataFrames

mutable struct Clock
    time::DateTime
    iteration::Int
    Δt::Second
end

include("io.jl")

"""
    Model{N,L,V,R,W}

Composite type that represents all different aspects of a Wflow Model, such as the
network, parameters, clock, configuration and input and output.
"""
struct Model{N,L,V,R,W}
    config::Config  # all configuration options
    network::N  # connectivity information, directed graph
    lateral::L  # lateral model that holds lateral state, moves along network
    vertical::V  # vertical model that holds vertical state, independent of each other
    clock::Clock  # to keep track of simulation time
    reader::R  # provides the model with dynamic input
    writer::W  # writes model output
end

# prevent a large printout of model components and arrays
Base.show(io::IO, m::Model) = print(io, "model of type ", typeof(m))

include("horizontal_process.jl")
include("hbv.jl")
include("sbm.jl")
include("reservoir_lake.jl")
include("hbv_model.jl")
include("sbm_model.jl")
include("flow.jl")
include("vertical_process.jl")
include("groundwater/connectivity.jl")
include("groundwater/aquifer.jl")
include("groundwater/boundary_conditions.jl")
include("sbm_gwf_model.jl")
include("utils.jl")

"""
    run_simulation(tomlpath::String)
    run_simulation(config::Config)
    run_simulation(model::Model)

Run an entire simulation starting either from a path to a TOML settings file,
a prepared `Config` object, or an initialized `Model` object. This allows more flexibility
if you want to for example modify a `Config` before initializing the `Model`.
"""
function run_simulation(tomlpath)
    config = Config(tomlpath)
    run_simulation(config)
end

function run_simulation(config::Config)
    modeltype = config.model.type

    model = if modeltype == "sbm"
        initialize_sbm_model(config)
    elseif modeltype == "sbm_gwf"
        initialize_sbm_gwf_model(config)
    elseif modeltype == "hbv"
        initialize_hbv_model(config)
    else
        error("unknown model type")
    end
    
    run_simulation(model)
end

function run_simulation(model::Model; close_files = true)
    @unpack network, config, writer, clock = model

    # in the case of sbm_gwf it's currently a bit hard to use dispatch
    update_func = config.model.type == "sbm_gwf" ? update_sbm_gwf : update

    while true
        model = update_func(model)
        is_finished(clock, config) && break
    end

    # write output state NetCDF
    # undo the clock advance at the end of the last iteration, since there won't
    # be a next step, and then the output state falls on the correct time
    rewind!(clock)
    write_netcdf_timestep(model, writer.state_dataset, writer.state_parameters)

    reset_clock!(model.clock, config)

    # option to support running function twice without re-initializing
    # and thus opening the NetCDF files
    if close_files
        Wflow.close_files(model, delete_output = false)
    end
    return model
end

end # module
