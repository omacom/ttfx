//! Regenerates the canonical geometry golden lines in Rust and diffs against
//! the CPython-generated fixture (tools/goldens/gen_geometry.py).

use ttfx::utils::geometry::{self, Coord};

#[test]
fn nonpositive_circle_diameters_are_empty() {
    for center in [Coord::new(0, 0), Coord::new(-10, 20), Coord::new(i64::MAX, i64::MIN)] {
        assert!(geometry::find_coords_in_circle(center, 0).is_empty());
    }
    for diameter in [-1, -5] {
        assert!(geometry::find_coords_in_circle(Coord::new(3, -2), diameter).is_empty());
    }
}

fn fbits(x: f64) -> String {
    x.to_le_bytes().iter().map(|b| format!("{b:02x}")).collect()
}

fn coords(cs: &[Coord]) -> String {
    cs.iter().map(|c| format!("{},{}", c.column, c.row)).collect::<Vec<_>>().join(";")
}

fn generate_lines() -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();

    for radius in [1, 2, 3, 5, 8, 13, 20] {
        for limit in [0, 7, 100] {
            for unique in [true, false] {
                let got = geometry::find_coords_on_circle(Coord::new(10, 10), radius, limit, unique);
                let u = if unique { "True" } else { "False" };
                lines.push(format!("on_circle r={radius} l={limit} u={u}: {}", coords(&got)));
            }
        }
    }

    for diameter in [1, 2, 3, 4, 7, 10, 15] {
        let got = geometry::find_coords_in_circle(Coord::new(5, -3), diameter);
        lines.push(format!("in_circle d={diameter}: {}", coords(&got)));
    }

    for distance in [0, 1, 2, 5] {
        lines.push(format!("in_rect d={distance}: {}", coords(&geometry::find_coords_in_rect(Coord::new(3, 4), distance))));
    }

    for (hw, hh) in [(0, 3), (3, 0), (1, 1), (4, 2), (5, 7)] {
        lines.push(format!("on_rect {hw},{hh}: {}", coords(&geometry::find_coords_on_rect(Coord::new(0, 0), hw, hh))));
    }

    for (origin, target) in [
        (Coord::new(0, 0), Coord::new(10, 5)),
        (Coord::new(3, 3), Coord::new(3, 3)),
        (Coord::new(-5, 2), Coord::new(7, -9)),
    ] {
        for offset in [0.0, 1.5, 4.0, 10.25, -2.0] {
            let c = geometry::extrapolate_along_ray(origin, target, offset);
            lines.push(format!(
                "extrapolate {},{}->{},{}+{offset:?}: {},{}",
                origin.column, origin.row, target.column, target.row, c.column, c.row
            ));
        }
    }

    let bezier_cases: Vec<(Coord, Vec<Coord>, Coord)> = vec![
        (Coord::new(0, 0), vec![Coord::new(5, 10)], Coord::new(10, 0)),
        (Coord::new(0, 0), vec![Coord::new(3, 8), Coord::new(7, -2)], Coord::new(12, 4)),
        (
            Coord::new(-4, -4),
            vec![Coord::new(0, 20), Coord::new(9, 9), Coord::new(-3, 2)],
            Coord::new(6, -6),
        ),
    ];
    for (start, control, end) in &bezier_cases {
        let mut pts = Vec::new();
        for i in 0..=20 {
            let t = i as f64 / 20.0;
            pts.push(geometry::find_coord_on_bezier_curve(*start, control, *end, t));
        }
        lines.push(format!("bezier {}cp: {}", control.len(), coords(&pts)));
        lines.push(format!(
            "bezier_len {}cp: {}",
            control.len(),
            fbits(geometry::find_length_of_bezier_curve(*start, control, *end))
        ));
    }

    let mut line_pts = Vec::new();
    for i in -5..=25 {
        let t = i as f64 / 20.0;
        line_pts.push(geometry::find_coord_on_line(Coord::new(-3, 7), Coord::new(14, -2), t));
    }
    lines.push(format!("on_line: {}", coords(&line_pts)));

    for double in [false, true] {
        let v = geometry::find_length_of_line(Coord::new(1, 2), Coord::new(-7, 11), double);
        let d = if double { "True" } else { "False" };
        lines.push(format!("line_len double={d}: {}", fbits(v)));
    }

    for coord in [Coord::new(1, 1), Coord::new(5, 3), Coord::new(10, 8), Coord::new(3, 8), Coord::new(10, 1)] {
        let v = geometry::find_normalized_distance_from_center(1, 8, 1, 10, coord).unwrap();
        lines.push(format!("norm_dist {},{}: {}", coord.column, coord.row, fbits(v)));
    }

    lines
}

#[test]
fn geometry_matches_python() {
    let fixture = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/geometry_goldens.txt"
    ))
    .expect("run tools/goldens/gen_geometry.py first");
    let expected: Vec<&str> = fixture.lines().collect();
    let actual = generate_lines();
    assert_eq!(expected.len(), actual.len(), "line count mismatch");
    let mut mismatches = 0;
    for (e, a) in expected.iter().zip(actual.iter()) {
        if e != a {
            if mismatches < 5 {
                eprintln!("expected: {e}\n  actual: {a}\n");
            }
            mismatches += 1;
        }
    }
    assert_eq!(mismatches, 0, "{mismatches} geometry golden lines diverge");
}
