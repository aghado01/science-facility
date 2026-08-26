using System;
using System.Collections.Generic;
using Synthetic;

namespace Synthetic.Manifolds;

/// <summary>
/// Generates clustered data directly in the Poincaré ball model of hyperbolic space (curvature K = −1).
/// Cluster centers are placed via exponential map from origin on a sphere in tangent space.
/// Points are sampled as tangent-space Gaussians at origin then translated via Möbius addition.
/// All points lie strictly inside the open unit ball, making PoincaréDistance the exact geodesic.
/// Perfect for testing SpcMetric.Poincaré with purity / susceptibility / radial-KL analysis.
/// Reference: standard Poincaré ball hyperbolic blob benchmark.
/// </summary>
public static class HyperbolicBlobs
{
    public static SyntheticDataset Generate(
        int clusterCount = 3,
        int pointsPerCluster = 2000,   // bumped from 50 → 6000 total, plausible-data scale
        int dimensions = 2,
        double separation = 3.0,
        double spread = 0.5,
        int seed = 42)
    {
        if (dimensions < 1)
            throw new ArgumentException("HyperbolicBlobs requires dimensions >= 1.");
        if (separation <= 0)
            throw new ArgumentException("separation must be positive.");

        var rng = new Random(seed);
        int n = clusterCount * pointsPerCluster;

        var features = new double[n][];
        var labels = new int[n];

        // 1. Place centers in tangent space at origin
        var tangentCenters = SyntheticData.PlaceCentroidsOnSphere(clusterCount, dimensions, separation, rng);

        // 2. Map centers to Poincaré ball via exp_0 (exact geodesic from origin)
        var centers = new double[clusterCount][];
        for (int c = 0; c < clusterCount; c++)
        {
            double[] tc = tangentCenters[c];
            double normSq = 0.0;
            for (int d = 0; d < dimensions; d++) normSq += tc[d] * tc[d];
            double norm = Math.Sqrt(normSq);

            double scale = (norm > 1e-12) ? Math.Tanh(norm) / norm : 0.0;
            var center = new double[dimensions];
            for (int d = 0; d < dimensions; d++)
                center[d] = scale * tc[d];
            centers[c] = center;
        }

        int idx = 0;
        for (int c = 0; c < clusterCount; c++)
        {
            double[] center = centers[c];

            for (int p = 0; p < pointsPerCluster; p++)
            {
                // Sample tangent vector (Gaussian noise at origin)
                var v = new double[dimensions];
                for (int d = 0; d < dimensions; d++)
                    v[d] = spread * SyntheticData.SampleStandardNormal(rng);

                // Map noise to ball via exp_0
                double vNormSq = 0.0;
                for (int d = 0; d < dimensions; d++) vNormSq += v[d] * v[d];
                double vNorm = Math.Sqrt(vNormSq);

                double vScale = (vNorm > 1e-12) ? Math.Tanh(vNorm) / vNorm : 0.0;
                var y = new double[dimensions];
                for (int d = 0; d < dimensions; d++)
                    y[d] = vScale * v[d];

                // Translate entire cluster via Möbius addition: center ⊕ y
                var point = MobiusAdd(center, y);

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
                ["dimensions"] = dimensions,
                ["separation"] = separation,
                ["spread"] = spread,
                ["seed"] = seed,
                ["model"] = "Poincaré ball (K = -1)",
                ["reference"] = "standard hyperbolic synthetic data for manifold testing (exp map + Möbius)"
            },
            Metadata = new SyntheticDatasetMeta(
                GeneratorName: nameof(HyperbolicBlobs),
                GeometryClass: "Manifold",
                TopologyTag: "blobs",
                HierarchyTag: "none",
                GTNumClusters: clusterCount,
                AmbientDimensionality: dimensions,
                LiteratureReference: "standard Poincaré ball hyperbolic blob benchmark")
        };
    }

    /// <summary>
    /// Möbius addition in the Poincaré ball (exact group operation preserving the ball).
    /// Used for cluster translation. Formula is the canonical one from hyperbolic geometry.
    /// </summary>
    private static double[] MobiusAdd(double[] c, double[] y)
    {
        int d = c.Length;
        double c2 = 0.0, y2 = 0.0, cy = 0.0;

        for (int i = 0; i < d; i++)
        {
            double ci = c[i], yi = y[i];
            c2 += ci * ci;
            y2 += yi * yi;
            cy += ci * yi;
        }

        double numerator = 1.0 + 2.0 * cy + y2;
        double denominator = 1.0 + 2.0 * cy + c2 * y2;

        var result = new double[d];
        for (int i = 0; i < d; i++)
        {
            result[i] = (numerator * c[i] + (1.0 - c2) * y[i]) / denominator;
        }
        return result;
    }
}


