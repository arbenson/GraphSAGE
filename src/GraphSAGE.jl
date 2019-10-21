module GraphSAGE
    using Statistics;
    using StatsBase: sample;
    using LightGraphs;
    using Flux;

    export graph_encoder;

    # sampler & aggregator
    struct SAGE{T}
        F::T;
        k::Int;
        A::Function;
    end

    function (c::SAGE)(G::AbstractGraph, node_list::Vector{Int}; kwargs...)
        F, k, A = c.F, c.k, c.A;

        sampled_nbrs_list = Vector{Vector{Int}}();
        for u in node_list
            nbrs = inneighbors(G, u);
            push!(sampled_nbrs_list, length(nbrs) > k ? sample(nbrs, k, replace=false) : nbrs);
        end

        # compute hidden vector of unique neighbors
        unique_nodes = union(node_list, sampled_nbrs_list...);
        u2i = Dict{Int,Int}(u=>i for (i,u) in enumerate(unique_nodes));
        hh0 = F(G, unique_nodes; kwargs);

        @assert length(hh0) > 0 "non of the vertices has incoming edge"
        sz = size(hh0[1]);

        # compute the mean hidden vector of the sampled neighbors
        hh1_ = Vector{AbstractVector}();
        for (u, sampled_nbrs) in zip(node_list, sampled_nbrs_list)
            h_nbrs = length(sampled_nbrs) != 0 ? A([hh0[u2i[v]] for v in sampled_nbrs]) : zeros(sz);
            push!(hh1_, vcat(hh0[u2i[u]], h_nbrs));
        end

        return hh1_;
    end

    Flux.@treelike SAGE;



    # transformer
    struct Transformer{T}
        S::SAGE;
        L::T;
    end

    function Transformer(S::SAGE, dim_h0::Integer, dim_h1::Integer, σ=relu)
        L = Dense(dim_h0*2, dim_h1, σ);

        return Transformer(S, L);
    end

    function (c::Transformer)(G::AbstractGraph, node_list::Vector{Int}; kwargs...)
        S, L = c.S, c.L;

        hh1 = L.(S(G, node_list; kwargs...));

        return hh1;
    end

    Flux.@treelike Transformer;



    # graph encoder
    function graph_encoder(features::Vector, dim_in::Integer, dim_out::Integer, dim_h::Integer, layers::Vector{String};
                           feature0::Vector=features, ks::Vector{Int}=repeat([typemax(Int)], length(layers)), σ=relu)
        @assert length(layers) > 0
        @assert length(layers) == length(ks)

        S2A = Dict{String,Function}("MeanSAGE" => (x->mean(x)), "MaxSAGE" => (x->max.(x...)), "SumSAGE" => (x->sum(x)));

        function get_feature(G::AbstractGraph, node_list::Vector{Int}; exclusion::Set{Int}=Set{Int}())
            return [u in exclusion ? feature0[u] : features[u] for u in node_list];
        end

        # first aggregator always pull input features
        sage = SAGE(get_feature, ks[1], S2A[layers[1]]);
        if length(layers) == 1
            # single layer, directly output
            tsfm = Transformer(sage, dim_in, dim_out, σ);
        else
            # multiple layer, first encode to hidden
            tsfm = Transformer(sage, dim_in, dim_h, σ);

            # the inner layers, hidden to hidden
            for i in 2:length(layers)-1
                sage = SAGE(tsfm, ks[i], S2A[layers[i]]);
                tsfm = Transformer(sage, dim_h, dim_h, σ);
            end

            sage = SAGE(tsfm, ks[end], S2A[layers[end]]);
            tsfm = Transformer(sage, dim_h, dim_out, σ);
        end

        return tsfm;
    end
end
