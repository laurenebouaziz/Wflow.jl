Base.@kwdef struct SurfaceFlow{T,R,L}
    β::T = 0.6                              # constant in Manning's equation
    sl::Vector{T}                           # Slope [m m⁻¹]
    n::Vector{T}                            # Manning's roughness [sl m⁻⅓]
    dl::Vector{T}                           # Drain length [m]
    q::Vector{T} = fill(0.0, length(sl))    # Discharge [m³ s⁻¹]
    q_av::Vector{T} = fill(0.0, length(sl)) # Average discharge [m³ s⁻¹]
    qlat::Vector{T} = fill(0.0, length(sl)) # Lateral discharge [m³ s⁻¹]
    h::Vector{T} = fill(0.0, length(sl))    # Water level [m]
    h_av::Vector{T} = fill(0.0, length(sl)) # Average water level [m]
    Δt::T                                   # Model time step [s]
    its::Int                                # Number of fixed iterations
    width::Vector{T}                        # Flow width [m]
    alpha_term::Vector{T} = pow.(n ./ sqrt.(sl), β)  # Constant part of α
    alpha_pow::T = (2.0 / 3.0) * β          # Used in the power part of α
    α::Vector{T} = alpha_term .* pow.(width .+ 2.0 .* h, alpha_pow) # Constant in momentum equation A = αQᵝ, based on Manning's equation
    eps::T = 1e-03                          # Maximum allowed change in α, if exceeded cross sectional area and h is recalculated
    cel::Vector{T} = fill(0.0, length(sl))  # Celerity of the kinematic wave
    to_river::Vector{T} = fill(0.0, length(sl)) # Part of overland flow [m³ s⁻¹] that flows to the river
    rivercells::Vector{Bool} = fill(false, length(sl)) # Location of river cells (0 or 1)
    wb_pit::Vector{Bool} = fill(false, length(sl)) # Boolean location (0 or 1) of a waterbody (wb, reservoir or lake).
    reservoir_index::Vector{Int} = fill(0, length(sl)) # map cell to 0 (no reservoir) or i (pick reservoir i in reservoir field)
    lake_index::Vector{Int} = fill(0, length(sl))      # map cell to 0 (no lake) or i (pick lake i in lake field)
    reservoir::R = nothing                  # Reservoir model struct of arrays
    lake::L = nothing                       # Lake model struct of arrays

    # TODO unclear why this causes a MethodError
    # function SurfaceFlow{T,R,L}(args...) where {T,R,L}
    #     equal_size_vectors(args)
    #     return new(args...)
    # end
end

statevars(::SurfaceFlow) = (:q,:h,:h_av,)

function update(
    sf::SurfaceFlow,
    network;
    frac_toriver = nothing,
    river = nothing,
    do_iter = false,
    doy = 0,
)
    @unpack graph, order = network

    n = length(order)
    # two options for iteration, fixed or based on courant number.
    if do_iter
        if sf.its > 0
            its = sf.its
        else
            # calculate celerity
            courant = zeros(n)
            for v in order
                if sf.q[v] > 0.0
                    sf.cel[v] = 1.0 / (sf.α[v] * sf.β * pow(sf.q[v], (sf.β - 1.0)))
                    courant[v] = (sf.Δt / sf.dl[v]) * sf.cel[v]
                end
            end
            filter!(x->x≠0.0,courant)
            its = isempty(courant) ? 1 : ceil(Int, (1.25 * quantile!(courant, 0.95)))
        end
    else
        its = 1
    end

    # sub time step
    adt = sf.Δt / its

    q_sum = zeros(n)
    h_sum = zeros(n)
    sf.to_river .= 0.0

    for _ = 1:its
        for v in order
            upstream_nodes = inneighbors(graph, v)
            # for overland flow frac_toriver and river cells need to be defined
            if (frac_toriver !== nothing) && (river !== nothing)
                # for a river cell without a reservoir or lake (wb_pit is false) part of the upstream surface flow
                # goes to the river (frac_toriver) and part goes to the surface flow reservoir (1.0 - frac_toriver)
                # upstream nodes with a reservoir or lake are excluded
                if river[v] && !sf.wb_pit[v] && sf.width[v] > 0.0
                    qin = sum(
                        sf.q[i] * (1.0 - frac_toriver[i])
                        for i in upstream_nodes if !sf.wb_pit[i]
                    )
                    # TODO: if in a loop should also take average!!!
                    sf.to_river[v] += sum(
                        sf.q[i] * frac_toriver[i] for i in upstream_nodes if !sf.wb_pit[i]
                    )
                    # for a river cell with a reservoir or lake (wb_pit is true) all upstream surface flow goes
                    # to the river.
                elseif river[v] && sf.wb_pit[v] && sf.width[v] == 0.0
                    sf.to_river[v]  += sum_at(sf.q, upstream_nodes)
                    qin = 0.0
                else
                    qin = sum_at(sf.q, upstream_nodes)
                end
                # for all the other cells all upstream surface flow goes to the surface flow reservoir.
            else
                qin = sum_at(sf.q, upstream_nodes)
            end
            if !isnothing(sf.reservoir) && sf.reservoir_index[v] != 0
                # run reservoir model and copy reservoir outflow to river cell
                i = sf.reservoir_index[v]
                update(sf.reservoir, i, qin, adt)
                sf.q[v] = sf.reservoir.outflow[i]

            elseif !isnothing(sf.lake) && sf.lake_index[v] != 0
                # run lake model and copy lake outflow to river cell
                i = sf.lake_index[v]
                update(sf.lake, i, qin, doy)
                sf.q[v] = sf.lake.outflow[i]
            else
                sf.q[v] =
                    kinematic_wave(qin, sf.q[v], sf.qlat[v], sf.α[v], sf.β, adt, sf.dl[v])
            end

            # update alpha
            crossarea = sf.α[v] * pow(sf.q[v], sf.β)
            sf.h[v] = crossarea / sf.width[v]
            wetper = sf.width[v] + (2.0 * sf.h[v]) # wetted perimeter
            α = sf.α[v]
            sf.α[v] = sf.alpha_term[v] * pow(wetper, sf.alpha_pow)

            if abs(α - sf.α[v]) > sf.eps
                crossarea = sf.α[v] * pow(sf.q[v], sf.β)
                sf.h[v] = crossarea / sf.width[v]
            end

            q_sum[v] += sf.q[v]
            h_sum[v] += sf.h[v]

        end

    end
    sf.q_av .= q_sum ./ its
    sf.h_av .= h_sum ./ its
    sf.to_river .= sf.to_river ./ its

end

Base.@kwdef struct LateralSSF{T}
    kh₀::Vector{T}                          # Horizontal hydraulic conductivity at soil surface [mm Δt⁻¹]
    f::Vector{T}                            # A scaling parameter [mm⁻¹] (controls exponential decline of kh₀)
    soilthickness::Vector{T}                # Soil thickness [mm]
    θₑ::Vector{T}                           # Effective porosity [-]
    Δt::T = 1.0                               # model time step
    βₗ::Vector{T}                           # Slope [m m⁻¹]
    dl::Vector{T}                           # Drain length [mm]
    dw::Vector{T}                           # Flow width [mm]
    zi::Vector{T} = fill(mv, length(f))     # Pseudo-water table depth [mm] (top of the saturated zone)
    exfiltwater::Vector{T} = fill(mv, length(f))  # Exfiltration [mm]  (groundwater above surface level, saturated excess conditions)
    recharge::Vector{T} = fill(mv, length(f))     # Net recharge to saturated store [mm]
    ssf::Vector{T} # Subsurface flow [mm³ Δt⁻¹]
    ssfin::Vector{T} = fill(mv, length(f))
    ssfmax::Vector{T} = ((kh₀ .* βₗ) ./ f) .* (1.0 .- exp.(-f .* soilthickness))     # Maximum subsurface flow [mm² Δt⁻¹]
    to_river::Vector{T} = zeros(length(f))  # Part of subsurface flow [mm³ Δt⁻¹] that flows to the river
    wb_pit::Vector{Bool} = zeros(Bool, length(f)) # Boolean location (0 or 1) of a waterbody (wb, reservoir or lake).

    function LateralSSF{T}(args...) where {T}
        equal_size_vectors(args)
        return new(args...)
    end
end

# depends on ini file settings (optional: glaciers, snow, irrigation)
statevars(::LateralSSF) = (:ssf,)

function update(ssf::LateralSSF, network, frac_toriver, river)
    @unpack graph, order = network
    for v in order
        upstream_nodes = inneighbors(graph, v)
        # for a river cell without a reservoir or lake (wb_pit is false) part of the upstream subsurface flow
        # goes to the river (frac_toriver) and part goes to the subsurface flow reservoir (1.0 - frac_toriver)
        # upstream nodes with a reservoir or lake are excluded
        if river[v] && !ssf.wb_pit[v]
            ssf.ssfin[v] = sum(
                ssf.ssf[i] * (1.0 - frac_toriver[i])
                for i in upstream_nodes if !ssf.wb_pit[i]
            )
            ssf.to_river[v] =
                sum(ssf.ssf[i] * frac_toriver[i] for i in upstream_nodes if !ssf.wb_pit[i])
            # for a river cell with a reservoir or lake (wb_pit is true) all upstream subsurface flow goes
            # to the river.
        elseif river[v] && ssf.wb_pit[v]
            ssf.to_river[v] = sum_at(ssf.ssf, upstream_nodes)
            ssf.ssfin[v] = 0.0
            # for all the other cells all upstream subsurface flow goes to the subsurface flow reservoir.
        else
            ssf.ssfin[v] = sum_at(ssf.ssf, upstream_nodes)
        end
        ssf.ssf[v], ssf.zi[v], ssf.exfiltwater[v] = kinematic_wave_ssf(
            ssf.ssfin[v],
            ssf.ssf[v],
            ssf.zi[v],
            ssf.recharge[v],
            ssf.kh₀[v],
            ssf.βₗ[v],
            ssf.θₑ[v],
            ssf.f[v],
            ssf.soilthickness[v],
            ssf.Δt,
            ssf.dl[v],
            ssf.dw[v],
            ssf.ssfmax[v],
        )
    end
end
