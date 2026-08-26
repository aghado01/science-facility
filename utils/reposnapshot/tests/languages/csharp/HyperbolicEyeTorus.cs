using System;
using System.Collections.Generic;
using Maths.Geometry;
using Synthetic;
using Synthetic.Euclidean;

namespace Synthetic.Manifolds;

/// <summary>
/// The <see cref="EyeTorusToy"/> realized natively on the Poincaré ball in any
/// ambient dimension — the hyperbolic eye. Shares the intrinsic
/// <see cref="EyeSkeleton"/> and its tangent-space sampler
/// (<see cref="EyeTorusToy.SampleLocal"/>) with the Euclidean toy; only the
/// realization differs: each eye-local tangent vector is pushed through
/// <see cref="PoincareBallManifold"/>'s exponential map at the ball origin (the
/// manifold is constructed at the skeleton's dimension). Background is sampled
/// native to the hyperbolic volume measure (radius ρ ∝ sinh²ρ), not projected.
/// </summary>
/// <remarks>
/// Origin-centered: the eye's outer extent maps to the geodesic shell
/// <c>ρ_max</c>, so the whole eye sits inside the Euclidean ball of radius
/// tanh(ρ_max/2). <see cref="EyeSkeleton.WarpStrength"/> interpolates the
/// placement between geometry-faithful (full conformal warp) and cosmetically
/// Euclidean. In 4-D the strokes' independent 2-planes carry over, so the rings
/// are unlinked on the ball too. <c>FlattenToPlane</c> on the output is the
/// naive geometry-ignoring projection.
/// </remarks>
public static class HyperbolicEyeTorus
{
    /// <summary>Geodesic shell radius used when the skeleton leaves ρ_max uncapped (∞).</summary>
    public const double DefaultMaxGeodesicRadius = 2.5;

    public static SyntheticDataset Generate(EyeTorusToy.EyeTorusToyConfig? cfg = null, int? overrideSeed = null)
    {
        cfg ??= new EyeTorusToy.EyeTorusToyConfig();
        int seed = overrideSeed ?? cfg.Seed;
        var rng = new Random(seed);

        var skeleton = EyeTorusToy.BuildSkeleton(cfg);
        int dim = skeleton.Center.Length;
        var (local, fine, coarse) = EyeTorusToy.SampleLocal(skeleton, cfg.StructureNoiseSigma, rng);

        double rhoMax = double.IsPositiveInfinity(skeleton.MaxGeodesicRadius)
            ? DefaultMaxGeodesicRadius
            : skeleton.MaxGeodesicRadius;
        double warp = Math.Clamp(skeleton.WarpStrength, 0.0, 1.0);
        double outerBallR = Math.Tanh(rhoMax / 2.0);

        double extent = 0.0;
        foreach (var v in local)
        {
            double nrm2 = 0.0;
            for (int d = 0; d < dim; d++) nrm2 += v[d] * v[d];
            double nrm = Math.Sqrt(nrm2);
            if (nrm > extent) extent = nrm;
        }
        if (extent < 1e-12) extent = 1.0;

        int totalStructure = local.Length;
        int structureGroups = skeleton.Strokes.Count + (skeleton.Pupil is null ? 0 : 1);
        int bgLabel = structureGroups;
        int backgroundPoints = (int)(totalStructure * cfg.BackgroundDensityRatio);
        int n = totalStructure + backgroundPoints;

        var manifold = new PoincareBallManifold(dim);
        var origin = new double[dim];
        var tan = new double[dim];
        var dst = new double[dim];

        var features = new double[n][];
        var fineLabels = new int[n];
        var coarseLabels = new int[n];

        for (int i = 0; i < totalStructure; i++)
        {
            var v = local[i];
            double nrm2 = 0.0;
            for (int d = 0; d < dim; d++) nrm2 += v[d] * v[d];
            double nrm = Math.Sqrt(nrm2);
            fineLabels[i] = fine[i];
            coarseLabels[i] = coarse[i];
            if (nrm < 1e-12) { features[i] = new double[dim]; continue; }

            double s = nrm / extent;                                  // normalized radius in [0,1]
            double faithfulNorm = s * rhoMax / 2.0;                   // exp_0 ⇒ geodesic radius s·ρ_max
            double cosmeticBallR = Math.Min(s * outerBallR, 1.0 - 1e-12);
            double cosmeticNorm = Math.Atanh(cosmeticBallR);          // exp_0 ⇒ linear apparent radius
            double normT = (1.0 - warp) * cosmeticNorm + warp * faithfulNorm;

            double k = normT / nrm;
            for (int d = 0; d < dim; d++) tan[d] = v[d] * k;
            manifold.ExpMap(origin, tan, dst);
            var p = new double[dim];
            for (int d = 0; d < dim; d++) p[d] = dst[d];
            features[i] = p;
        }

        // Native ball-volume white blanket: geodesic-sphere area ∝ sinh²ρ, so
        // uniform-in-hyperbolic-volume draws ρ ∝ sinh²ρ with a uniform S^(d-1)
        // direction — NOT the Euclidean-uniform points a projection would give.
        if (backgroundPoints > 0)
        {
            double sinhMax = Math.Sinh(rhoMax);
            double sinhMaxSq = sinhMax * sinhMax;
            int idx = totalStructure, placed = 0;
            long guard = 0, guardMax = (long)backgroundPoints * 1000 + 1000;
            while (placed < backgroundPoints)
            {
                double rho;
                if (guard++ < guardMax)
                {
                    rho = rng.NextDouble() * rhoMax;
                    double sh = Math.Sinh(rho);
                    if (rng.NextDouble() > sh * sh / sinhMaxSq) continue;
                }
                else
                {
                    rho = rhoMax;
                }

                double n2 = 0.0;
                for (int d = 0; d < dim; d++) { tan[d] = SampleStandardNormal(rng); n2 += tan[d] * tan[d]; }
                double dn = Math.Sqrt(n2);
                if (dn < 1e-12) { for (int d = 0; d < dim; d++) tan[d] = 0.0; tan[0] = 1.0; dn = 1.0; }

                double tn = rho / 2.0; // exp_0 tangent norm for geodesic radius ρ
                for (int d = 0; d < dim; d++) tan[d] = tan[d] / dn * tn;
                manifold.ExpMap(origin, tan, dst);
                var p = new double[dim];
                for (int d = 0; d < dim; d++) p[d] = dst[d];
                features[idx] = p;
                fineLabels[idx] = bgLabel;
                coarseLabels[idx] = 1;
                idx++;
                placed++;
            }
        }

        return new SyntheticDataset
        {
            Features = features,
            Labels = fineLabels,
            ClusterCount = structureGroups,
            LabelsByLevel = new[] { coarseLabels, fineLabels },
            Parameters = new Dictionary<string, object>
            {
                ["generator"] = nameof(HyperbolicEyeTorus),
                ["model"] = "Poincare ball",
                ["dimension"] = dim,
                ["maxGeodesicRadius"] = rhoMax,
                ["warpStrength"] = warp,
                ["outerBallRadius"] = outerBallR,
                ["totalPoints"] = n,
                ["structurePoints"] = totalStructure,
                ["backgroundPoints"] = backgroundPoints,
                ["backgroundLabel"] = bgLabel,
                ["structureGroups"] = structureGroups,
                ["seed"] = seed,
            },
            Metadata = new SyntheticDatasetMeta(
                GeneratorName: nameof(HyperbolicEyeTorus),
                GeometryClass: "Manifold",
                TopologyTag: "toroidal-hierarchical",
                HierarchyTag: "multi-scale-density",
                GTNumClusters: structureGroups,
                AmbientDimensionality: dim,
                LiteratureReference: "Blatt, Wiseman, Domany 1996 PRL 76:3251, Fig. 1 — Poincaré-ball (hyperbolic) realization",
                SuggestedMetric: "poincare")
        };
    }

    private static double SampleStandardNormal(Random rng)
    {
        double u1 = 1.0 - rng.NextDouble();
        double u2 = 1.0 - rng.NextDouble();
        return Math.Sqrt(-2.0 * Math.Log(u1)) * Math.Cos(2.0 * Math.PI * u2);
    }
}
