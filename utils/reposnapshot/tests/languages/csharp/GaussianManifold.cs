using System;
using System.Collections.Generic;
using Synthetic;

namespace Synthetic.Manifolds;

/// <summary>
/// Each data point is a (mu, log_sigma) pair describing a 1D Gaussian.
/// Clusters correspond to regions of the Gaussian statistical manifold.
/// Centers are arranged on the Poincaré half-plane so that Euclidean
/// distance in (mu, log_sigma) space gives a neighborhood structure
/// different from the manifold geodesic (Fisher-Rao).
/// Reference: Gaussian statistical manifold benchmark (Fisher-Rao half-plane).
/// </summary>
public static class GaussianManifold
{
    public static SyntheticDataset Generate(
        int clusterCount = 3,
        int pointsPerCluster = 2000,   // bumped from 50 → 6000 total, plausible-data scale
        double clusterRadius = 0.3,
        int dimensions = 2,
        int seed = 42)
    {
        if (dimensions < 2)
            throw new ArgumentException("GaussianManifold requires dimensions >= 2.");
        var rng = new Random(seed);
        int n = clusterCount * pointsPerCluster;
        var features = new double[n][];
        var labels = new int[n];

        // Centers: alternating log_sigma produces pairs that are close in
        // Euclidean (mu, log_sigma) space but distant on the manifold.
        var centers = new double[clusterCount][];
        for (int c = 0; c < clusterCount; c++)
        {
            centers[c] = new double[2];
            double t = (double)c / Math.Max(1, clusterCount - 1);
            centers[c][0] = -2.0 + 4.0 * t;
            centers[c][1] = (c % 2 == 0) ? -0.5 : 0.5;
        }

        int idx = 0;
        for (int c = 0; c < clusterCount; c++)
        {
            for (int p = 0; p < pointsPerCluster; p++)
            {
                var point = new double[dimensions];
                point[0] = centers[c][0] + clusterRadius * SyntheticData.SampleStandardNormal(rng);
                point[1] = centers[c][1] + clusterRadius * SyntheticData.SampleStandardNormal(rng);
                features[idx] = point;
                labels[idx] = c;
                idx++;
            }
        }

        return new SyntheticDataset
        {
            Features = features,
            Labels = labels,
            ClusterCount = clusterCount,
            LabelsByLevel = new[] { labels },
            Parameters = new Dictionary<string, object>
            {
                ["clusterCount"] = clusterCount,
                ["pointsPerCluster"] = pointsPerCluster,
                ["clusterRadius"] = clusterRadius,
                ["dimensions"] = dimensions,
                ["seed"] = seed,
                ["featureLayout"] = "(mu, log_sigma) on Gaussian statistical manifold"
            },
            Metadata = new SyntheticDatasetMeta(
                GeneratorName: nameof(GaussianManifold),
                GeometryClass: "Manifold",
                TopologyTag: "manifold",
                HierarchyTag: "none",
                GTNumClusters: clusterCount,
                AmbientDimensionality: dimensions,
                LiteratureReference: "Gaussian statistical manifold benchmark (Fisher-Rao half-plane)",
                FutureMetric: "FisherRaoHalfPlane")
        };
    }
}
