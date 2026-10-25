// Copyright 2021 Google LLC
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! Exact Celebi/Wu/Wsmeans port from material_color_utilities 0.13.0.
//! Pixel order, alpha behavior, numeric order and the pinned Dart VM RNG are
//! preserved. Flutter retains Score and dynamic ColorScheme semantics.

use std::collections::HashMap;

const MAX_PIXELS: usize = 112 * 112;
const COLORS: usize = 128;
const SIDE: usize = 33;
const SIZE: usize = SIDE * SIDE * SIDE;

/// Input is the same premultiplied RGBA readback supplied to Flutter Celebi.
/// Output is ordered ABGR/population pairs, exactly like colorToCount.
pub fn quantize_rgba(
    bytes: &[u8],
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Vec<(u32, usize)>, String> {
    check()?;
    if bytes.is_empty() || !bytes.len().is_multiple_of(4) || bytes.len() / 4 > MAX_PIXELS {
        return Err("invalid palette pixel buffer".into());
    }
    let mut lookup = HashMap::new();
    let mut colors = Vec::new();
    let mut counts = Vec::new();
    for pixel in bytes.as_chunks::<4>().0 {
        let color = u32::from_le_bytes([pixel[0], pixel[1], pixel[2], pixel[3]]);
        let index = *lookup.entry(color).or_insert_with(|| {
            colors.push(color);
            counts.push(0_usize);
            colors.len() - 1
        });
        counts[index] += 1;
    }
    let starts = Wu::new(&colors, &counts).quantize(check)?;
    wsmeans(&colors, &counts, starts, check)
}

#[derive(Clone, Copy, Default)]
struct Cube {
    low: [usize; 3],
    high: [usize; 3],
    volume: usize,
}

fn index(r: usize, g: usize, b: usize) -> usize {
    r * SIDE * SIDE + g * SIDE + b
}

struct Wu {
    weights: Vec<i64>,
    moments: [Vec<i64>; 3],
    squares: Vec<f64>,
}

impl Wu {
    fn new(colors: &[u32], counts: &[usize]) -> Self {
        let mut result = Self {
            weights: vec![0; SIZE],
            moments: std::array::from_fn(|_| vec![0; SIZE]),
            squares: vec![0.0; SIZE],
        };
        for (&color, &count) in colors.iter().zip(counts) {
            if color >> 24 < 255 {
                continue;
            }
            let rgb = [
                ((color >> 16) & 255) as i64,
                ((color >> 8) & 255) as i64,
                (color & 255) as i64,
            ];
            let location = index(
                (rgb[0] as usize >> 3) + 1,
                (rgb[1] as usize >> 3) + 1,
                (rgb[2] as usize >> 3) + 1,
            );
            result.weights[location] += count as i64;
            for (channel, value) in rgb.iter().enumerate() {
                result.moments[channel][location] += value * count as i64;
            }
            result.squares[location] +=
                (count as i64 * (rgb[0] * rgb[0] + rgb[1] * rgb[1] + rgb[2] * rgb[2])) as f64;
        }
        result
    }

    fn prefix(&mut self, check: &dyn Fn() -> Result<(), String>) -> Result<(), String> {
        for r in 1..SIDE {
            check()?;
            let mut areas = [[0_i64; SIDE]; 4];
            let mut area_square = [0.0; SIDE];
            for g in 1..SIDE {
                let mut lines = [0_i64; 4];
                let mut line_square = 0.0;
                for b in 1..SIDE {
                    let location = index(r, g, b);
                    let previous = index(r - 1, g, b);
                    lines[0] += self.weights[location];
                    for channel in 0..3 {
                        lines[channel + 1] += self.moments[channel][location];
                    }
                    line_square += self.squares[location];
                    for channel in 0..4 {
                        areas[channel][b] += lines[channel];
                    }
                    area_square[b] += line_square;
                    self.weights[location] = self.weights[previous] + areas[0][b];
                    for channel in 0..3 {
                        self.moments[channel][location] =
                            self.moments[channel][previous] + areas[channel + 1][b];
                    }
                    self.squares[location] = self.squares[previous] + area_square[b];
                }
            }
        }
        Ok(())
    }

    fn quantize(mut self, check: &dyn Fn() -> Result<(), String>) -> Result<Vec<u32>, String> {
        self.prefix(check)?;
        let mut cubes = vec![Cube::default(); COLORS];
        cubes[0].high = [32; 3];
        let mut variances = [0.0; COLORS];
        let (mut next, mut count, mut i) = (0, COLORS, 1);
        while i < COLORS {
            check()?;
            if let Some((one, two)) = self.cut(cubes[next]) {
                cubes[next] = one;
                cubes[i] = two;
                variances[next] = if one.volume > 1 {
                    self.variance(one)
                } else {
                    0.0
                };
                variances[i] = if two.volume > 1 {
                    self.variance(two)
                } else {
                    0.0
                };
            } else {
                variances[next] = 0.0;
                i -= 1;
            }
            next = 0;
            let mut maximum = variances[0];
            for (candidate, value) in variances.iter().enumerate().take(i + 1).skip(1) {
                if *value > maximum {
                    maximum = *value;
                    next = candidate;
                }
            }
            if maximum <= 0.0 {
                count = i + 1;
                break;
            }
            i += 1;
        }
        let mut result = Vec::new();
        for cube in cubes.into_iter().take(count) {
            let weight = volume(cube, &self.weights);
            if weight > 0 {
                let rgb = self
                    .moments
                    .each_ref()
                    .map(|values| (volume(cube, values) as f64 / weight as f64).round() as u32);
                let color = 0xff000000 | rgb[0] << 16 | rgb[1] << 8 | rgb[2];
                // Dart's Map.fromEntries removes duplicate keys, in first order.
                if !result.contains(&color) {
                    result.push(color);
                }
            }
        }
        Ok(result)
    }

    fn variance(&self, cube: Cube) -> f64 {
        let rgb = self.moments.each_ref().map(|values| volume(cube, values));
        volume_float(cube, &self.squares)
            - (rgb[0] * rgb[0] + rgb[1] * rgb[1] + rgb[2] * rgb[2]) as f64
                / volume(cube, &self.weights) as f64
    }

    fn cut(&self, cube: Cube) -> Option<(Cube, Cube)> {
        let mut best = [(0.0, None); 3];
        let whole = [
            volume(cube, &self.moments[0]),
            volume(cube, &self.moments[1]),
            volume(cube, &self.moments[2]),
            volume(cube, &self.weights),
        ];
        for (direction, best_cut) in best.iter_mut().enumerate() {
            for position in cube.low[direction] + 1..cube.high[direction] {
                let mut half = cube;
                half.high[direction] = position;
                let first = [
                    volume(half, &self.moments[0]),
                    volume(half, &self.moments[1]),
                    volume(half, &self.moments[2]),
                    volume(half, &self.weights),
                ];
                if first[3] == 0 || whole[3] - first[3] == 0 {
                    continue;
                }
                let second = std::array::from_fn::<_, 4, _>(|i| whole[i] - first[i]);
                let score = (first[0] * first[0] + first[1] * first[1] + first[2] * first[2])
                    as f64
                    / first[3] as f64
                    + (second[0] * second[0] + second[1] * second[1] + second[2] * second[2])
                        as f64
                        / second[3] as f64;
                if score > best_cut.0 {
                    *best_cut = (score, Some(position));
                }
            }
        }
        let direction = if best[0].0 >= best[1].0 && best[0].0 >= best[2].0 {
            0
        } else if best[1].0 >= best[0].0 && best[1].0 >= best[2].0 {
            1
        } else {
            2
        };
        let position = best[direction].1?;
        let (mut one, mut two) = (cube, cube);
        one.high[direction] = position;
        two.low[direction] = position;
        one.volume =
            (one.high[0] - one.low[0]) * (one.high[1] - one.low[1]) * (one.high[2] - one.low[2]);
        two.volume =
            (two.high[0] - two.low[0]) * (two.high[1] - two.low[1]) * (two.high[2] - two.low[2]);
        Some((one, two))
    }
}

fn volume(c: Cube, v: &[i64]) -> i64 {
    v[index(c.high[0], c.high[1], c.high[2])]
        - v[index(c.high[0], c.high[1], c.low[2])]
        - v[index(c.high[0], c.low[1], c.high[2])]
        + v[index(c.high[0], c.low[1], c.low[2])]
        - v[index(c.low[0], c.high[1], c.high[2])]
        + v[index(c.low[0], c.high[1], c.low[2])]
        + v[index(c.low[0], c.low[1], c.high[2])]
        - v[index(c.low[0], c.low[1], c.low[2])]
}

fn volume_float(c: Cube, v: &[f64]) -> f64 {
    v[index(c.high[0], c.high[1], c.high[2])]
        - v[index(c.high[0], c.high[1], c.low[2])]
        - v[index(c.high[0], c.low[1], c.high[2])]
        + v[index(c.high[0], c.low[1], c.low[2])]
        - v[index(c.low[0], c.high[1], c.high[2])]
        + v[index(c.low[0], c.high[1], c.low[2])]
        + v[index(c.low[0], c.low[1], c.high[2])]
        - v[index(c.low[0], c.low[1], c.low[2])]
}

fn lab(color: u32) -> [f64; 3] {
    let linear = |value: u32| {
        let n = value as f64 / 255.0;
        if n <= 0.040449936 {
            n / 12.92 * 100.0
        } else {
            ((n + 0.055) / 1.055).powf(2.4) * 100.0
        }
    };
    let (r, g, b) = (
        linear(color >> 16 & 255),
        linear(color >> 8 & 255),
        linear(color & 255),
    );
    let f = |t: f64| {
        if t > 216.0 / 24389.0 {
            t.powf(1.0 / 3.0)
        } else {
            ((24389.0 / 27.0) * t + 16.0) / 116.0
        }
    };
    let x = f((0.41233895 * r + 0.35762064 * g + 0.18051042 * b) / 95.047);
    let y = f((0.2126 * r + 0.7152 * g + 0.0722 * b) / 100.0);
    let z = f((0.01932141 * r + 0.11916382 * g + 0.95034478 * b) / 108.883);
    [116.0 * y - 16.0, 500.0 * (x - y), 200.0 * (y - z)]
}

fn color(point: [f64; 3]) -> u32 {
    let fy = (point[0] + 16.0) / 116.0;
    let inverse = |ft: f64| {
        let cube = ft * ft * ft;
        if cube > 216.0 / 24389.0 {
            cube
        } else {
            (116.0 * ft - 16.0) / (24389.0 / 27.0)
        }
    };
    let x = inverse(point[1] / 500.0 + fy) * 95.047;
    let y = inverse(fy) * 100.0;
    let z = inverse(fy - point[2] / 200.0) * 108.883;
    let channel = |linear: f64| {
        let n = linear / 100.0;
        let v = if n <= 0.0031308 {
            n * 12.92
        } else {
            1.055 * n.powf(1.0 / 2.4) - 0.055
        };
        (v * 255.0).round().clamp(0.0, 255.0) as u32
    };
    let r = channel(3.2413774792388685 * x + -1.5376652402851851 * y + -0.49885366846268053 * z);
    let g = channel(-0.9691452513005321 * x + 1.8758853451067872 * y + 0.04156585616912061 * z);
    let b = channel(0.05562093689691305 * x + -0.20395524564742123 * y + 1.0571799111220335 * z);
    0xff000000 | r << 16 | g << 8 | b
}

fn distance(one: [f64; 3], two: [f64; 3]) -> f64 {
    let l = one[0] - two[0];
    let a = one[1] - two[1];
    let b = one[2] - two[2];
    l * l + a * a + b * b
}

fn wsmeans(
    colors: &[u32],
    counts: &[usize],
    starting: Vec<u32>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Vec<(u32, usize)>, String> {
    let points: Vec<_> = colors.iter().map(|value| lab(*value)).collect();
    let cluster_count = COLORS.min(points.len());
    let mut clusters: Vec<_> = starting.into_iter().map(lab).collect();
    if clusters.len() < cluster_count {
        let mut random = DartRandom::new(0x42688);
        let mut chosen = Vec::new();
        while chosen.len() < cluster_count - clusters.len() {
            let candidate = random.next_int(points.len());
            if !chosen.contains(&candidate) {
                chosen.push(candidate);
            }
        }
        clusters.extend(chosen.into_iter().map(|i| points[i]));
    }
    let mut indices: Vec<_> = (0..points.len()).map(|i| i % cluster_count).collect();
    let mut distances = vec![vec![0.0_f64; cluster_count]; cluster_count];
    let mut sums = vec![0_usize; cluster_count];
    for iteration in 0..5 {
        check()?;
        for i in 0..cluster_count {
            for j in i + 1..cluster_count {
                let value = distance(clusters[i], clusters[j]);
                distances[j][i] = value;
                distances[i][j] = value;
            }
            // Match pinned Dart's in-place row sorting, including subsequent
            // updates to this already-sorted matrix. Its index matrix is unused.
            distances[i].sort_by(f64::total_cmp);
        }
        let mut moved = 0;
        for (i, point) in points.iter().enumerate() {
            if i.is_multiple_of(256) {
                check()?;
            }
            let previous = indices[i];
            let previous_distance = distance(*point, clusters[previous]);
            let mut minimum = previous_distance;
            let mut new = None;
            for j in 0..cluster_count {
                if distances[previous][j] >= 4.0 * previous_distance {
                    continue;
                }
                let value = distance(*point, clusters[j]);
                if value < minimum {
                    minimum = value;
                    new = Some(j);
                }
            }
            if let Some(new) = new {
                moved += 1;
                indices[i] = new;
            }
        }
        if moved == 0 && iteration > 0 {
            break;
        }
        let mut component_sums = vec![[0.0; 3]; cluster_count];
        sums.fill(0);
        for (i, point) in points.iter().enumerate() {
            let cluster = indices[i];
            sums[cluster] += counts[i];
            for channel in 0..3 {
                component_sums[cluster][channel] += point[channel] * counts[i] as f64;
            }
        }
        for i in 0..cluster_count {
            clusters[i] = if sums[i] == 0 {
                [0.0; 3]
            } else {
                component_sums[i].map(|value| value / sums[i] as f64)
            };
        }
    }
    let mut result = Vec::new();
    for i in 0..cluster_count {
        if sums[i] == 0 {
            continue;
        }
        let rgb = color(clusters[i]);
        if !result.iter().any(|(key, _)| *key == rgb) {
            result.push((rgb, sums[i]));
        }
    }
    check()?;
    Ok(result)
}

// Multiply-with-carry and Thomas Wang seed mixing mirror the pinned Dart VM
// Random implementation (Dart SDK, Copyright the Dart project authors, BSD).
struct DartRandom(u64);
impl DartRandom {
    fn new(mut n: u64) -> Self {
        n = (!n).wrapping_add(n << 21);
        n ^= n >> 24;
        n = n.wrapping_mul(265);
        n ^= n >> 14;
        n = n.wrapping_mul(21);
        n ^= n >> 28;
        n = n.wrapping_add(n << 31);
        if n == 0 {
            n = 0x5a17;
        }
        let mut value = Self(n);
        for _ in 0..4 {
            value.next();
        }
        value
    }
    fn next(&mut self) {
        self.0 = 0xffffda61 * (self.0 & 0xffffffff) + (self.0 >> 32);
    }
    fn next_int(&mut self, maximum: usize) -> usize {
        loop {
            self.next();
            let random = self.0 & 0xffffffff;
            if maximum.is_power_of_two() {
                return random as usize & (maximum - 1);
            }
            let result = random % maximum as u64;
            if random - result + maximum as u64 <= 1_u64 << 32 {
                return result as usize;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn solid_pixels_and_invalid_or_cancelled_requests() {
        assert_eq!(
            quantize_rgba(&[51, 102, 153, 255].repeat(100), &|| Ok(())).unwrap(),
            vec![(0xff996633, 100)]
        );
        assert!(quantize_rgba(&[0; 3], &|| Ok(())).is_err());
        assert_eq!(
            quantize_rgba(&[0; 4], &|| Err("cancelled".into())).unwrap_err(),
            "cancelled"
        );
    }

    #[test]
    fn ordered_populations_match_pinned_material_dart_vectors() {
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("native_palette/fixtures.json")).unwrap();
        for f in fixture["fixtures"].as_array().unwrap() {
            let kind = f["kind"].as_str().unwrap();
            let mut state = f["seed"].as_u64().unwrap() as u32;
            let count = f["count"].as_u64().unwrap() as usize;
            let mut bytes = Vec::new();
            for i in 0..count {
                state = state.wrapping_mul(1664525).wrapping_add(1013904223);
                let mut rgb = state & 0xffffff;
                let mut alpha = 255;
                if kind == "transparent" {
                    alpha = 0;
                }
                if kind == "mixed_alpha" {
                    alpha = state >> 24 & 255;
                }
                if kind == "single_bin" {
                    rgb = 0x606060 | (rgb & 0x070707);
                }
                if kind == "gradient" {
                    rgb = (((i % 112) as u32 * 255 / 111) << 16)
                        | (((i / 112) as u32 * 255 / 111) << 8)
                        | 90;
                }
                if kind == "ties" {
                    rgb = [0xff0000, 0x00ff00, 0x0000ff, 0x444444][i % 4];
                }
                bytes.extend_from_slice(&(alpha << 24 | rgb).to_le_bytes());
            }
            let actual = quantize_rgba(&bytes, &|| Ok(())).unwrap();
            assert_eq!(
                serde_json::to_value(actual).unwrap(),
                f["colors"],
                "{kind} seed {}",
                f["seed"]
            );
        }
        let mut random = DartRandom::new(0x42688);
        let actual: Vec<_> = (0..20).map(|_| random.next_int(1024)).collect();
        assert_eq!(serde_json::to_value(actual).unwrap(), fixture["rng1024"]);
    }
}
