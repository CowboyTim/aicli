// The 3D view of a model file on the page (.glb, .stl): three.js (MIT, see vendor/three/LICENSE and NOTICE).
// The page loads this module on the first click on a model's "view in 3D" (import("/viewer.js")), so nothing
// here runs before that. The model's bytes come from GET /file (the session's project), parse here, and are
// drawn in a canvas of their own that turns with the mouse or a finger (OrbitControls). A glTF that names a
// web address for a part of it is not followed: only what the file carries itself (data: and blob:) is loaded.
import * as THREE from "three";
import { GLTFLoader } from "./vendor/three/examples/jsm/loaders/GLTFLoader.js";
import { STLLoader } from "./vendor/three/examples/jsm/loaders/STLLoader.js";
import { OrbitControls } from "./vendor/three/examples/jsm/controls/OrbitControls.js";

// the largest model the page reads (bytes); a bigger one is refused before it is parsed
export const MAX_BYTES = 50 * 1024 * 1024;

// the object (a THREE.Object3D) of a model's bytes; kind is "glb" or "stl"
export function parseModel(bytes, kind) {
  if (kind === "stl") {
    try {
      const geometry = new STLLoader().parse(bytes);
      const material = new THREE.MeshStandardMaterial({ color: 0xb8c0cc, roughness: 0.55, metalness: 0.05, flatShading: true });
      const group = new THREE.Group();
      group.add(new THREE.Mesh(geometry, material));
      // an STL stands on z = 0 with z up (generate_3d writes it so, for a printer): the view's up is y
      group.rotation.x = -Math.PI / 2;
      return Promise.resolve(group);
    } catch (err) {
      return Promise.reject(err);
    }
  }
  return new Promise(function (resolve, reject) {
    const manager = new THREE.LoadingManager();
    manager.setURLModifier(function (url) {
      return /^(data|blob):/.test(url) ? url : "data:,";
    });
    new GLTFLoader(manager).parse(bytes, "", function (gltf) { resolve(gltf.scene); }, reject);
  });
}

// moves the object to the origin and backs the camera off until it fits the view
function fit(object, camera, controls) {
  const box = new THREE.Box3().setFromObject(object);
  if (box.isEmpty()) { throw new Error("the model has no geometry"); }
  const center = box.getCenter(new THREE.Vector3());
  const size = box.getSize(new THREE.Vector3());
  object.position.sub(center);
  const radius = Math.max(size.length() / 2, 1e-6);
  const dist = radius / Math.sin(THREE.MathUtils.degToRad(camera.fov / 2)) * 1.1;
  camera.position.set(0.6, 0.5, 1).normalize().multiplyScalar(dist);
  camera.near = radius / 100;
  camera.far = radius * 100;
  camera.updateProjectionMatrix();
  controls.target.set(0, 0, 0);
  controls.update();
}

// shows the model at url in container (a DOM element, its size set by the page); returns { dispose() }, which
// frees the WebGL context. Throws (a promise rejects) when the file cannot be read, parsed, or drawn.
export async function show(container, url, kind) {
  const resp = await fetch(url, { credentials: "same-origin" });
  if (!resp.ok) { throw new Error("the file could not be read (HTTP " + resp.status + ")"); }
  if (Number(resp.headers.get("Content-Length") || 0) > MAX_BYTES) { throw new Error("the model is bigger than 50 MB"); }
  const bytes = await resp.arrayBuffer();
  if (bytes.byteLength > MAX_BYTES) { throw new Error("the model is bigger than 50 MB"); }
  const object = await parseModel(bytes, kind);

  const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
  const canvas = renderer.domElement;
  let controls = null;
  let ro = null;
  try {
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    const scene = new THREE.Scene();
    scene.add(new THREE.HemisphereLight(0xffffff, 0x556070, 1.2));
    const sun = new THREE.DirectionalLight(0xffffff, 1.8);
    sun.position.set(1, 2, 3);
    scene.add(sun);
    scene.add(object);
    const camera = new THREE.PerspectiveCamera(35, 1, 0.001, 1e9);
    controls = new OrbitControls(camera, canvas);
    fit(object, camera, controls);
    const draw = function () { renderer.render(scene, camera); };
    controls.addEventListener("change", draw);
    const resize = function () {
      const w = Math.max(container.clientWidth, 1);
      const h = Math.max(container.clientHeight, 1);
      renderer.setSize(w, h, false);
      camera.aspect = w / h;
      camera.updateProjectionMatrix();
      draw();
    };
    ro = new ResizeObserver(resize);
    container.textContent = "";
    container.appendChild(canvas);
    ro.observe(container);
    resize();
  } catch (err) {
    if (controls) { controls.dispose(); }
    renderer.dispose();
    renderer.forceContextLoss();
    throw err;
  }
  return {
    dispose: function () {
      if (ro) { ro.disconnect(); }
      controls.dispose();
      object.traverse(function (o) {
        if (o.geometry) { o.geometry.dispose(); }
        [].concat(o.material || []).forEach(function (m) {
          Object.values(m).forEach(function (v) { if (v && v.isTexture) { v.dispose(); } });
          m.dispose();
        });
      });
      renderer.dispose();
      renderer.forceContextLoss();
      canvas.remove();
    }
  };
}
