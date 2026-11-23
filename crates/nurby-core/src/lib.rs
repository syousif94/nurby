//! nurby-core: the Rust core behind the Nurby iPad/iPhone CAD app.
//!
//! A [`Studio`] is one open design: an in-process, headless SolidCraft session behind
//! SolidCraft's own MCP tool layer (`solidcraft-mcp`). The agent in the app calls exactly those
//! tools (`execute`, `batch`, `inspect_design`, `list_commands`…), the UI calls the same engine
//! commands through [`Studio::execute`], and the viewport draws [`Studio::meshes`].
//!
//! SolidCraft's session is single-threaded, so every call runs on one worker thread of the
//! studio's own; Swift may call from any thread (calls block until done).

uniffi::setup_scaffolding!();

use serde_json::{Value, json};
use solidcraft_engine::Session;
use solidcraft_engine::schema::ParamCheck;
use solidcraft_mcp::{Backend, Headless, Server};
use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Mutex;
use std::sync::mpsc;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum NurbyError {
    #[error("{msg}")]
    Failed { msg: String },
}

fn fail(msg: impl Into<String>) -> NurbyError {
    NurbyError::Failed { msg: msg.into() }
}

/// What a tool call returned: the text the model reads, and whether it is an error.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ToolResult {
    pub text: String,
    pub is_error: bool,
}

/// One body's display triangles, in model millimetres. `positions` and `normals` are xyz
/// triples; `edges` are line segments (pairs of xyz points) of the body's feature edges.
/// `triangle_faces` names each triangle's B-rep face index and `segment_edges` each segment's
/// B-rep edge index: what `select.set` takes as `index` for a face or an edge.
#[derive(Debug, Clone, uniffi::Record)]
pub struct BodyMesh {
    pub name: String,
    pub positions: Vec<f32>,
    pub normals: Vec<f32>,
    pub indices: Vec<u32>,
    pub triangle_faces: Vec<u32>,
    pub edges: Vec<f32>,
    pub segment_edges: Vec<u32>,
}

/// The headless session, shared between the MCP server (as its backend) and the studio's own
/// calls (meshes, file I/O). Lives only on the worker thread.
#[derive(Clone)]
struct Shared(Rc<RefCell<Headless>>);

impl Backend for Shared {
    fn call(&mut self, method: &str, params: Value) -> Result<Value, String> {
        self.0.borrow_mut().call(method, params)
    }
    fn supports_plugin_tools(&mut self) -> bool {
        self.0.borrow_mut().supports_plugin_tools()
    }
    fn has_ui(&self) -> bool {
        self.0.borrow().has_ui()
    }
    fn describe(&self) -> String {
        "Nurby (in-process SolidCraft session on iPad/iPhone; no window, renders with the CPU)".into()
    }
    fn design_path(&self) -> Option<String> {
        self.0.borrow().design_path()
    }
    fn in_process(&self) -> bool {
        true
    }
    fn param_check(&self) -> ParamCheck {
        self.0.borrow().param_check()
    }
}

struct Worker {
    server: Server,
    shared: Shared,
    next_id: u64,
}

impl Worker {
    fn rpc(&mut self, method: &str, params: Value) -> Result<Value, NurbyError> {
        self.next_id += 1;
        let msg = json!({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params});
        let reply = self.server.handle(msg).ok_or_else(|| fail(format!("{method}: no reply")))?;
        if let Some(e) = reply.get("error") {
            return Err(fail(e.get("message").and_then(Value::as_str).unwrap_or("error").to_string()));
        }
        Ok(reply.get("result").cloned().unwrap_or(Value::Null))
    }

    fn session<R>(&self, f: impl FnOnce(&mut Session) -> R) -> R {
        f(&mut self.shared.0.borrow_mut().session)
    }
}

type Job = Box<dyn FnOnce(&mut Worker) + Send>;

/// One open design.
#[derive(uniffi::Object)]
pub struct Studio {
    jobs: Mutex<mpsc::Sender<Job>>,
    instructions: String,
}

impl Studio {
    fn run<R: Send + 'static>(&self, f: impl FnOnce(&mut Worker) -> R + Send + 'static) -> Result<R, NurbyError> {
        let (tx, rx) = mpsc::channel();
        let job: Job = Box::new(move |w| {
            let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| f(w)));
            let _ = tx.send(r);
        });
        self.jobs.lock().map_err(|_| fail("studio lock poisoned"))?.send(job).map_err(|_| fail("studio stopped"))?;
        match rx.recv() {
            Ok(Ok(r)) => Ok(r),
            Ok(Err(p)) => {
                let what = p.downcast_ref::<String>().cloned().or_else(|| p.downcast_ref::<&str>().map(|s| s.to_string()));
                Err(fail(format!("the kernel crashed: {}", what.unwrap_or_else(|| "unknown panic".into()))))
            }
            Err(_) => Err(fail("studio stopped")),
        }
    }
}

#[uniffi::export]
impl Studio {
    /// A new, empty design. Tool calls may read and write files only under `files_dir`
    /// (the app's Documents folder) and SolidCraft's own scratch folders.
    #[uniffi::constructor]
    pub fn new(files_dir: String) -> Result<Self, NurbyError> {
        let (tx, rx) = mpsc::channel::<Job>();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<String, String>>();
        std::thread::Builder::new()
            .name("nurby-studio".into())
            .stack_size(256 << 20)
            .spawn(move || {
                let shared = Shared(Rc::new(RefCell::new(Headless::default())));
                let scope = solidcraft_mcp::agent_scope([PathBuf::from(&files_dir)]);
                let server = Server::new(Box::new(shared.clone())).with_path_scope(Some(scope));
                let mut w = Worker { server, shared, next_id: 0 };
                let init = w
                    .rpc("initialize", json!({"protocolVersion": solidcraft_mcp::PROTOCOL_VERSION, "capabilities": {}, "clientInfo": {"name": "nurby", "version": env!("CARGO_PKG_VERSION")}}))
                    .map(|r| r.get("instructions").and_then(Value::as_str).unwrap_or_default().to_string())
                    .map_err(|e| e.to_string());
                let _ = w.server.handle(json!({"jsonrpc": "2.0", "method": "notifications/initialized"}));
                let _ = ready_tx.send(init);
                while let Ok(job) = rx.recv() {
                    job(&mut w);
                }
            })
            .map_err(|e| fail(format!("could not start the studio: {e}")))?;
        let instructions = ready_rx.recv().map_err(|_| fail("studio failed to start"))?.map_err(fail)?;
        Ok(Self { jobs: Mutex::new(tx), instructions })
    }

    /// SolidCraft's instructions for agents (how to model with its tools).
    pub fn instructions(&self) -> String {
        self.instructions.clone()
    }

    /// The MCP tool definitions as a JSON array: `[{name, description, inputSchema, …}]`.
    pub fn tools_json(&self) -> Result<String, NurbyError> {
        self.run(|w| w.rpc("tools/list", json!({})).map(|r| r.get("tools").cloned().unwrap_or(json!([])).to_string()))?
    }

    /// Run one MCP tool with JSON arguments. Failures are results with `is_error`, so the model
    /// can read them; only a broken call (bad JSON) is an `Err`.
    pub fn call_tool(&self, name: String, args_json: String) -> Result<ToolResult, NurbyError> {
        let args: Value = if args_json.trim().is_empty() { json!({}) } else { serde_json::from_str(&args_json).map_err(|e| fail(format!("arguments are not JSON: {e}")))? };
        self.run(move |w| {
            let r = w.rpc("tools/call", json!({"name": name, "arguments": args}))?;
            let is_error = r.get("isError").and_then(Value::as_bool).unwrap_or(false);
            let mut text = String::new();
            for c in r.get("content").and_then(Value::as_array).into_iter().flatten() {
                match c.get("type").and_then(Value::as_str) {
                    Some("text") => {
                        if !text.is_empty() {
                            text.push('\n');
                        }
                        text.push_str(c.get("text").and_then(Value::as_str).unwrap_or_default());
                    }
                    Some(other) => text.push_str(&format!("\n[{other} content not shown]")),
                    None => {}
                }
            }
            Ok(ToolResult { text, is_error })
        })?
    }

    /// Run one engine command (`edit.undo`, `file.export`, `parameters.change`…) as the UI does.
    /// Returns the command's JSON result.
    pub fn execute(&self, command: String, params_json: String) -> Result<String, NurbyError> {
        let params: Value = if params_json.trim().is_empty() { json!({}) } else { serde_json::from_str(&params_json).map_err(|e| fail(format!("parameters are not JSON: {e}")))? };
        self.run(move |w| w.session(|s| s.execute(&command, &params).map(|v| v.to_string()).map_err(|e| fail(e.to_string()))))?
    }

    /// The design as SolidCraft's `document.inspect` describes it (features, parameters,
    /// bodies, sketches), as JSON.
    pub fn inspect_json(&self) -> Result<String, NurbyError> {
        self.run(|w| w.shared.0.borrow_mut().call("document.inspect", json!({})).map(|v| v.to_string()).map_err(fail))?
    }

    /// The regions a sketch closes (what `sketch.inspect` lists as `profiles`, same order and
    /// indices, which `solid.extrude {profiles: [index], exact_regions: true}` takes), each as
    /// polylines in sketch mm: `[{index, outer: [[x,y]…], holes: [[[x,y]…]…]}]`. Curves are
    /// sampled for display and tap-picking. A region's boundary can run along pieces of curves
    /// (where shapes overlap), which only the evaluated region knows.
    pub fn sketch_regions(&self, sketch: u64) -> Result<String, NurbyError> {
        self.run(move |w| {
            w.session(|s| {
                let st = s.model.state();
                let ss = st.sketch(sketch).ok_or_else(|| fail(format!("no sketch {sketch}")))?;
                let out: Vec<Value> = ss
                    .profiles
                    .iter()
                    .enumerate()
                    .map(|(i, p)| {
                        let region = serde_json::to_value(&p.region).unwrap_or(Value::Null);
                        let outer = sample_loop(&region["outer"]);
                        let holes: Vec<Value> = region["holes"].as_array().map(|h| h.iter().map(sample_loop).collect()).unwrap_or_default();
                        json!({"index": i, "outer": outer, "holes": holes})
                    })
                    .collect();
                Ok(Value::Array(out).to_string())
            })
        })?
    }

    /// Display meshes of every visible body.
    pub fn meshes(&self) -> Result<Vec<BodyMesh>, NurbyError> {
        self.run(|w| {
            w.session(|s| {
                let st = s.world_state().map_err(|e| fail(e.to_string()))?;
                let hidden = &s.doc.visibility.hidden_bodies;
                let mut out = Vec::new();
                for b in st.bodies.iter().filter(|b| !hidden.contains(&b.name)) {
                    let m = b.mesh();
                    let mut positions = Vec::with_capacity(m.positions.len() * 3);
                    for p in &m.positions {
                        positions.extend([p.x as f32, p.y as f32, p.z as f32]);
                    }
                    let mut normals = Vec::with_capacity(m.normals.len() * 3);
                    for n in &m.normals {
                        normals.extend([n.x as f32, n.y as f32, n.z as f32]);
                    }
                    let indices = m.triangles.iter().flatten().copied().collect();
                    let triangle_faces = m.tri_face.clone();
                    let mut edges = Vec::new();
                    let mut segment_edges = Vec::new();
                    for (i, poly) in m.edges.iter().enumerate() {
                        let skip = m.seams.get(i).copied().unwrap_or(false) || m.smooth_edges.get(i).copied().unwrap_or(false);
                        if skip {
                            continue;
                        }
                        for seg in poly.windows(2) {
                            segment_edges.push(i as u32);
                            for p in seg {
                                edges.extend([p.x as f32, p.y as f32, p.z as f32]);
                            }
                        }
                    }
                    out.push(BodyMesh { name: b.name.clone(), positions, normals, indices, triangle_faces, edges, segment_edges });
                }
                Ok(out)
            })
        })?
    }
}

/// A region loop (`Loop2` as JSON: `{segs: [{type: line|arc|cubic|conic|bezier, …}]}`) as one
/// polyline `[[x,y]…]` (the closing point not repeated).
fn sample_loop(lp: &Value) -> Value {
    fn v(p: &Value) -> Option<(f64, f64)> {
        // `Vec2` serializes as `[x, y]` (older records as `{x, y}`).
        Some((p[0].as_f64().or(p["x"].as_f64())?, p[1].as_f64().or(p["y"].as_f64())?))
    }
    fn bezier(ctrl: &[(f64, f64)], t: f64) -> (f64, f64) {
        let mut q = ctrl.to_vec();
        while q.len() > 1 {
            q = q.windows(2).map(|w| (w[0].0 + (w[1].0 - w[0].0) * t, w[0].1 + (w[1].1 - w[0].1) * t)).collect();
        }
        q.first().copied().unwrap_or((0.0, 0.0))
    }
    let mut pts: Vec<(f64, f64)> = Vec::new();
    for seg in lp["segs"].as_array().into_iter().flatten() {
        match seg["type"].as_str().unwrap_or("") {
            "line" => pts.extend(v(&seg["a"])),
            "arc" => {
                let (Some(c), Some(r), Some(a0), Some(sw)) = (v(&seg["center"]), seg["radius"].as_f64(), seg["start"].as_f64(), seg["sweep"].as_f64()) else { continue };
                let n = ((sw.abs() / (std::f64::consts::PI / 32.0)).ceil() as usize).clamp(2, 128);
                for k in 0..n {
                    let a = a0 + sw * k as f64 / n as f64;
                    pts.push((c.0 + r * a.cos(), c.1 + r * a.sin()));
                }
            }
            "cubic" => {
                let c: Vec<_> = ["p0", "p1", "p2", "p3"].iter().filter_map(|k| v(&seg[*k])).collect();
                if c.len() == 4 {
                    pts.extend((0..24).map(|k| bezier(&c, k as f64 / 24.0)));
                }
            }
            "conic" => {
                let (Some(a), Some(m), Some(b), Some(w)) = (v(&seg["a"]), v(&seg["apex"]), v(&seg["b"]), seg["w"].as_f64()) else { continue };
                for k in 0..24 {
                    let t = k as f64 / 24.0;
                    let (b0, b1, b2) = ((1.0 - t) * (1.0 - t), 2.0 * t * (1.0 - t) * w, t * t);
                    let d = b0 + b1 + b2;
                    pts.push(((a.0 * b0 + m.0 * b1 + b.0 * b2) / d, (a.1 * b0 + m.1 * b1 + b.1 * b2) / d));
                }
            }
            "bezier" => {
                let n = seg["n"].as_u64().unwrap_or(0) as usize;
                let c: Vec<_> = seg["p"].as_array().into_iter().flatten().take(n + 1).filter_map(v).collect();
                if c.len() == n + 1 && n > 0 {
                    pts.extend((0..32).map(|k| bezier(&c, k as f64 / 32.0)));
                }
            }
            _ => {}
        }
    }
    Value::Array(pts.into_iter().map(|(x, y)| json!([x, y])).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tool(s: &Studio, name: &str, args: Value) -> ToolResult {
        let r = s.call_tool(name.into(), args.to_string()).unwrap();
        assert!(!r.is_error, "{name}: {}", r.text);
        r
    }

    #[test]
    fn the_agent_builds_a_plate_with_a_hole_and_it_meshes() {
        let dir = std::env::temp_dir().join("nurby-core-test");
        std::fs::create_dir_all(&dir).unwrap();
        let s = Studio::new(dir.to_string_lossy().into()).unwrap();
        assert!(s.instructions().len() > 100);
        let tools: Value = serde_json::from_str(&s.tools_json().unwrap()).unwrap();
        let names: Vec<&str> = tools.as_array().unwrap().iter().filter_map(|t| t["name"].as_str()).collect();
        assert!(names.contains(&"execute") && names.contains(&"batch"), "{names:?}");

        tool(&s, "execute", json!({"command": "sketch.create", "params": {"plane": "XY", "name": "Plate"}}));
        tool(&s, "execute", json!({"command": "sketch.rectangle.two_point", "params": {"p0": [0, 0], "p1": [90, 60]}}));
        tool(&s, "execute", json!({"command": "sketch.finish", "params": {}}));
        tool(&s, "execute", json!({"command": "solid.extrude", "params": {"sketch": "Plate", "distance": 4}}));
        let m = s.meshes().unwrap();
        assert_eq!(m.len(), 1);
        assert!(m[0].indices.len() >= 36 && !m[0].edges.is_empty());
        assert_eq!(m[0].triangle_faces.len() * 3, m[0].indices.len());
        assert_eq!(m[0].segment_edges.len() * 6, m[0].edges.len());

        // A tap on the top face selects it in SolidCraft, where the agent reads it.
        let top = (0..m[0].triangle_faces.len()).find(|&t| (0..3).all(|k| m[0].positions[m[0].indices[t * 3 + k] as usize * 3 + 2] > 3.9)).unwrap();
        let face = m[0].triangle_faces[top];
        let r = s.execute("select.set".into(), json!({"items": [{"type": "face", "body": "Body1", "index": face, "point": [45, 30, 4]}]}).to_string()).unwrap();
        assert!(r.contains("\"selected\":1"), "{r}");
        assert!(s.inspect_json().unwrap().contains("\"type\":\"face\""));

        let path = dir.join("plate.step");
        let _ = std::fs::remove_file(&path);
        tool(&s, "export", json!({"path": path.to_string_lossy()}));
        assert!(std::fs::read_to_string(&path).unwrap().contains("ISO-10303-21"));

        s.execute("edit.undo".into(), "{}".into()).unwrap();
        assert!(s.meshes().unwrap().is_empty());
        assert!(s.inspect_json().unwrap().contains("Plate"));
    }
}

#[cfg(test)]
mod modelling {
    //! The engine calls the touch UI relies on for picking regions, constraints and reordering.
    use super::*;

    fn ok(s: &Studio, c: &str, p: Value) -> Value {
        serde_json::from_str(&s.execute(c.into(), p.to_string()).unwrap_or_else(|e| panic!("{c}: {e}"))).unwrap()
    }

    #[test]
    fn regions_pick_constraints_and_reorder() {
        let dir = std::env::temp_dir().join("nurby-core-modelling");
        std::fs::create_dir_all(&dir).unwrap();
        let s = Studio::new(dir.to_string_lossy().into()).unwrap();
        // A rectangle and a circle on its corner: three regions, two bounded by pieces of curves.
        ok(&s, "sketch.create", json!({"plane": "XY", "name": "A"}));
        ok(&s, "sketch.rectangle.two_point", json!({"p0": [0, 0], "p1": [60, 40]}));
        ok(&s, "sketch.circle.center", json!({"center": [60, 40], "radius": 15}));
        let made = ok(&s, "sketch.line", json!({"points": [[0, 0], [60, 40]], "construction": true}));
        let id = ok(&s, "sketch.inspect", json!({}))["id"].as_u64().unwrap();
        let regions: Value = serde_json::from_str(&s.sketch_regions(id).unwrap()).unwrap();
        let regions = regions.as_array().unwrap();
        assert_eq!(regions.len(), 3, "the construction line makes no region");
        assert!(regions.iter().all(|r| r["outer"].as_array().unwrap().len() >= 3));
        // The lens where they overlap stays inside both shapes.
        assert!(regions.iter().any(|r| r["outer"].as_array().unwrap().iter().all(|p| p[0].as_f64().unwrap() >= 44.9 && p[1].as_f64().unwrap() <= 40.01)));
        // A line's middle, and a model-free constraint on it.
        let l = made["curves"][0].as_str().unwrap().to_string();
        ok(&s, "sketch.construction", json!({"curves": [l], "value": true}));
        ok(&s, "sketch.finish", json!({}));
        ok(&s, "solid.extrude", json!({"sketch": "A", "distance": 5, "profiles": [2], "exact_regions": true}));
        let d = ok(&s, "timeline.inspect", json!({"feature": "Extrude1"}));
        assert_eq!(d["definition"]["profiles"]["type"], "indices", "{d}");
        ok(&s, "timeline.edit", json!({"feature": "Extrude1", "set": {"profiles": {"type": "indices", "indices": [0, 1]}}}));

        // A sketch on the top face: project an edge as construction, tie a point to its middle.
        ok(&s, "sketch.create", json!({"plane": "XY", "name": "B"}));
        let line = ok(&s, "sketch.line", json!({"points": [[5, 5], [20, 5]]}));
        let l = line["curves"][0].as_str().unwrap().to_string();
        let proj = ok(&s, "sketch.project", json!({"refs": [{"edge": [30, 0, 5]}], "construction": true}));
        let e = proj["created"]["curves"][0].as_str().unwrap().to_string();
        ok(&s, "sketch.constraint.coincident", json!({"a": format!("{l}.start"), "b": {"midpoint": e}}));
        // A construction line between two existing points by id (a projected face's diagonal).
        let ends = proj["created"]["points"].clone();
        ok(&s, "sketch.line", json!({"points": [ends[0], ends[1]], "construction": true}));
        let pts = ok(&s, "sketch.inspect", json!({}))["points"].clone();
        let start = pts.as_array().unwrap().iter().find(|p| p["id"] == format!("{l}.start")).unwrap();
        assert!((start["at"][0].as_f64().unwrap() - 30.0).abs() < 1e-6, "{start}");
        ok(&s, "sketch.finish", json!({}));

        ok(&s, "sketch.create", json!({"plane": "XZ", "name": "C"}));
        ok(&s, "sketch.circle.center", json!({"center": [0, 0], "radius": 4}));
        ok(&s, "sketch.finish", json!({}));

        // Reordering refuses a move that breaks a feature (B projects Extrude1's edge) and makes
        // one that doesn't.
        assert!(s.execute("timeline.reorder".into(), json!({"feature": "B", "position": 1}).to_string()).is_err());
        ok(&s, "timeline.reorder", json!({"feature": "C", "position": 1}));
        let names: Vec<String> = serde_json::from_str::<Value>(&s.inspect_json().unwrap()).unwrap()["timeline"]
            .as_array().unwrap().iter().map(|f| f["name"].as_str().unwrap().to_string()).collect();
        assert_eq!(names, ["A", "C", "Extrude1", "B"]);
    }
}
