//! Waypoint, Segment, Path, Motion — state from engine/motion.py. The stepping
//! logic that fires events (Path.step, Motion.move, activate_path) lives on
//! EngineCtx (ctx.rs) so actions run inline at upstream emission points.

use std::rc::Rc;

use crate::engine::events::WaypointKey;
use crate::utils::easing::Easing;
use crate::utils::geometry::{self, Coord};
use crate::utils::ordered_map::OrderedMap;
use crate::utils::pycompat::round_half_even;

/// Waypoints are cloned constantly — into segments, into origin segments on
/// every path activation, and into event keys — so both owned fields are
/// reference counted and a clone is two refcount bumps.
#[derive(Debug, Clone, PartialEq)]
pub struct Waypoint {
    pub waypoint_id: Rc<str>,
    pub coord: Coord,
    pub bezier_control: Option<Rc<[Coord]>>,
}

impl Waypoint {
    pub fn key(&self) -> WaypointKey {
        WaypointKey {
            coord: self.coord,
            waypoint_id: self.waypoint_id.clone(),
            bezier_control: self.bezier_control.clone(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Segment {
    pub start: Waypoint,
    pub end: Waypoint,
    pub distance: f64,
    pub enter_event_triggered: bool,
    pub exit_event_triggered: bool,
}

impl Segment {
    pub fn new(start: Waypoint, end: Waypoint, distance: f64) -> Self {
        Segment { start, end, distance, enter_event_triggered: false, exit_event_triggered: false }
    }
}

#[derive(Debug, Clone)]
pub struct Path {
    pub path_id: String,
    pub speed: f64,
    pub ease: Option<Easing>,
    pub layer: Option<i64>,
    pub hold_time: i64,
    pub loop_: bool,
    pub segments: Vec<Segment>,
    pub waypoints: Vec<Waypoint>,
    pub total_distance: f64,
    pub current_step: i64,
    pub max_steps: i64,
    pub hold_time_remaining: i64,
    pub last_distance_reached: f64,
    /// Distance of the synthetic origin segment set at activation (upstream
    /// keeps the Segment object; only its distance is read back).
    pub origin_segment: Option<Segment>,
}

impl Path {
    pub fn new(
        path_id: &str,
        speed: f64,
        ease: Option<Easing>,
        layer: Option<i64>,
        hold_time: i64,
        loop_: bool,
    ) -> Result<Self, String> {
        if speed <= 0.0 {
            return Err("Path speed must be greater than 0.".to_string());
        }
        Ok(Path {
            path_id: path_id.to_string(),
            speed,
            ease,
            layer,
            hold_time,
            loop_,
            segments: Vec::new(),
            waypoints: Vec::new(),
            total_distance: 0.0,
            current_step: 0,
            max_steps: 0,
            hold_time_remaining: hold_time,
            last_distance_reached: 0.0,
            origin_segment: None,
        })
    }

    /// Path.new_waypoint: auto-id like scenes; duplicate explicit id errors.
    pub fn new_waypoint(
        &mut self,
        coord: Coord,
        bezier_control: Option<Vec<Coord>>,
        waypoint_id: &str,
    ) -> Result<Waypoint, String> {
        let waypoint_id: Rc<str> = if waypoint_id.is_empty() {
            let mut current_id = self.waypoints.len();
            loop {
                let candidate = current_id.to_string();
                if !self.waypoints.iter().any(|w| *w.waypoint_id == *candidate) {
                    break Rc::from(candidate);
                }
                current_id += 1;
            }
        } else {
            if self.waypoints.iter().any(|w| *w.waypoint_id == *waypoint_id) {
                return Err(format!("duplicate waypoint id: {waypoint_id}"));
            }
            Rc::from(waypoint_id)
        };
        // Python: empty tuple bezier_control is falsy -> None
        let bezier_control = bezier_control.filter(|v| !v.is_empty()).map(Rc::from);
        let waypoint = Waypoint { waypoint_id, coord, bezier_control };
        self.add_waypoint_to_path(waypoint.clone());
        Ok(waypoint)
    }

    /// Path._add_waypoint_to_path.
    fn add_waypoint_to_path(&mut self, waypoint: Waypoint) {
        self.waypoints.push(waypoint);
        if self.waypoints.len() < 2 {
            return;
        }
        let prev = &self.waypoints[self.waypoints.len() - 2];
        let waypoint = &self.waypoints[self.waypoints.len() - 1];
        let distance_from_previous = match &waypoint.bezier_control {
            Some(control) => geometry::find_length_of_bezier_curve(prev.coord, control, waypoint.coord),
            None => geometry::find_length_of_line(prev.coord, waypoint.coord, true),
        };
        self.total_distance += distance_from_previous;
        self.segments.push(Segment::new(prev.clone(), waypoint.clone(), distance_from_previous));
        self.max_steps = round_half_even(self.total_distance / self.speed);
    }

    pub fn query_waypoint(&self, waypoint_id: &str) -> Result<&Waypoint, String> {
        self.waypoints
            .iter()
            .find(|w| *w.waypoint_id == *waypoint_id)
            .ok_or_else(|| format!("waypoint not found: {waypoint_id}"))
    }
}

/// engine/motion.py Motion: per-character movement state. `active_path` and
/// `completed_path` are path ids (upstream holds object references; Path
/// equality is by id).
#[derive(Debug, Clone)]
pub struct Motion {
    pub paths: OrderedMap<Path>,
    pub current_coord: Coord,
    pub previous_coord: Coord,
    pub active_path: Option<Rc<str>>,
    pub completed_path: Option<Rc<str>>,
}

impl Motion {
    pub fn new(input_coord: Coord) -> Self {
        Motion {
            paths: OrderedMap::new(),
            current_coord: input_coord,
            previous_coord: Coord::new(-1, -1),
            active_path: None,
            completed_path: None,
        }
    }

    pub fn set_coordinate(&mut self, coord: Coord) {
        self.current_coord = coord;
    }

    /// Motion.new_path: auto-id probing; duplicate explicit id errors.
    pub fn new_path(
        &mut self,
        speed: f64,
        ease: Option<Easing>,
        layer: Option<i64>,
        hold_time: i64,
        loop_: bool,
        path_id: &str,
    ) -> Result<String, String> {
        let path_id = if path_id.is_empty() {
            let mut current_id = self.paths.len();
            loop {
                let candidate = current_id.to_string();
                if !self.paths.contains_key(&candidate) {
                    break candidate;
                }
                current_id += 1;
            }
        } else {
            if self.paths.contains_key(path_id) {
                return Err(format!("duplicate path id: {path_id}"));
            }
            path_id.to_string()
        };
        let path = Path::new(&path_id, speed, ease, layer, hold_time, loop_)?;
        self.paths.insert(path_id.clone(), path);
        Ok(path_id)
    }

    pub fn movement_is_complete(&self) -> bool {
        self.active_path.is_none()
    }

    /// Motion.deactivate_path: None clears unconditionally; otherwise only
    /// clears when the given path is the active one.
    pub fn deactivate_path(&mut self, path_id: Option<&str>) {
        match path_id {
            None => self.active_path = None,
            Some(id) => {
                if self.active_path.as_deref() == Some(id) {
                    self.active_path = None;
                }
            }
        }
    }
}
