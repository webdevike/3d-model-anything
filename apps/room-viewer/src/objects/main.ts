import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { MTLLoader } from 'three/addons/loaders/MTLLoader.js';
import { OBJLoader } from 'three/addons/loaders/OBJLoader.js';
import { appURL } from '../asset-base';

interface ObjectIndexEntry { id: string; name: string; builtAt: string }
interface ObjectManifest {
  id: string;
  name: string;
  obj: string;
  mtl: string | null;
  usdz: string | null;
  photos: number;
  builtAt: string;
}

const element = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const status = element<HTMLOutputElement>('object-status');
const errorBox = element<HTMLParagraphElement>('object-error');

const formatDate = (iso: string) => {
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? iso : date.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
};

/** Missing or malformed JSON resolves to null so callers can show an empty state instead of crashing. */
async function fetchJSON<T>(path: string): Promise<T | null> {
  try {
    const response = await fetch(appURL(path), { cache: 'no-cache' });
    if (!response.ok) return null;
    return await response.json() as T;
  } catch {
    return null;
  }
}

function showError(message: string) {
  status.value = 'Unavailable';
  errorBox.textContent = message;
  errorBox.hidden = false;
}

async function showList() {
  status.value = 'Scanned objects';
  const list = element<HTMLElement>('object-list');
  const items = element<HTMLUListElement>('object-items');
  const index = await fetchJSON<ObjectIndexEntry[]>('objects/index.json');
  const entries = (Array.isArray(index) ? index : [])
    .filter(entry => entry && typeof entry.id === 'string')
    .sort((a, b) => String(b.builtAt).localeCompare(String(a.builtAt)));
  for (const entry of entries) {
    const link = document.createElement('a');
    link.href = `${appURL('objects.html')}?id=${encodeURIComponent(entry.id)}`;
    const name = document.createElement('span');
    name.textContent = entry.name || entry.id;
    const built = document.createElement('time');
    built.dateTime = entry.builtAt;
    built.textContent = formatDate(entry.builtAt);
    link.append(name, built);
    const item = document.createElement('li');
    item.append(link);
    items.append(item);
  }
  element<HTMLElement>('object-empty').hidden = entries.length > 0;
  status.value = entries.length ? `${entries.length} object${entries.length === 1 ? '' : 's'}` : 'No objects yet';
  list.hidden = false;
}

/** Radial alpha fade so the ground disc dissolves into the background instead of ending in a hard edge. */
function discFade() {
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = 256;
  const context = canvas.getContext('2d')!;
  const gradient = context.createRadialGradient(128, 128, 0, 128, 128, 128);
  gradient.addColorStop(0, '#fff');
  gradient.addColorStop(0.6, '#fff');
  gradient.addColorStop(1, '#000');
  context.fillStyle = gradient;
  context.fillRect(0, 0, 256, 256);
  return new THREE.CanvasTexture(canvas);
}

async function loadModel(base: URL, manifest: ObjectManifest) {
  const objectLoader = new OBJLoader();
  if (manifest.mtl) {
    const materials = await new MTLLoader().loadAsync(new URL(manifest.mtl, base).href);
    materials.preload();
    objectLoader.setMaterials(materials);
  }
  return objectLoader.loadAsync(new URL(manifest.obj, base).href);
}

async function showObject(id: string) {
  const back = element<HTMLAnchorElement>('back-to-list');
  back.hidden = false;
  status.value = 'Loading object…';
  const folder = `objects/${encodeURIComponent(id)}/`;
  const manifest = await fetchJSON<ObjectManifest>(`${folder}manifest.json`);
  if (!manifest || typeof manifest.obj !== 'string') {
    showError(`No built model was found for “${id}”. Build it with npm run object -- <zip>, or go back to the object list.`);
    return;
  }
  document.title = `${manifest.name || id} · Scanned objects`;
  const base = new URL(appURL(folder), location.href);

  const canvas = element<HTMLCanvasElement>('object-canvas');
  canvas.hidden = false;
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.toneMapping = THREE.AgXToneMapping;
  renderer.toneMappingExposure = 1.1;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFShadowMap;

  const scene = new THREE.Scene();
  scene.background = new THREE.Color('#2b302d');
  const pmrem = new THREE.PMREMGenerator(renderer);
  const studio = new RoomEnvironment();
  const environment = pmrem.fromScene(studio, 0.04);
  scene.environment = environment.texture;
  scene.environmentIntensity = 0.8;
  studio.dispose();
  pmrem.dispose();

  const camera = new THREE.PerspectiveCamera(35, 1, 0.01, 100);
  const controls = new OrbitControls(camera, canvas);
  controls.enableDamping = true;

  let model: THREE.Group;
  try {
    model = await loadModel(base, manifest);
  } catch (error) {
    canvas.hidden = true;
    renderer.dispose();
    showError(`Could not load the model for “${manifest.name || id}”: ${error instanceof Error ? error.message : String(error)}`);
    return;
  }

  const meshes: THREE.Mesh[] = [];
  model.traverse(node => {
    if (!(node instanceof THREE.Mesh)) return;
    node.castShadow = true;
    node.receiveShadow = true;
    meshes.push(node);
  });

  // Center on the footprint and rest the lowest point on the ground plane.
  const bounds = new THREE.Box3().setFromObject(model);
  if (bounds.isEmpty()) {
    canvas.hidden = true;
    renderer.dispose();
    showError(`The model for “${manifest.name || id}” contains no geometry.`);
    return;
  }
  const center = bounds.getCenter(new THREE.Vector3());
  model.position.set(-center.x, -bounds.min.y, -center.z);
  scene.add(model);
  const size = bounds.getSize(new THREE.Vector3());
  const radius = Math.max(size.length() / 2, 1e-3);
  const focus = new THREE.Vector3(0, size.y / 2, 0);

  const disc = new THREE.Mesh(
    new THREE.CircleGeometry(radius * 2.2, 96),
    new THREE.MeshStandardMaterial({ color: '#4a514c', roughness: 0.95, alphaMap: discFade(), transparent: true, depthWrite: false }),
  );
  disc.rotation.x = -Math.PI / 2;
  disc.position.y = -radius * 0.002; // keep the model's flat base from z-fighting the ground
  disc.receiveShadow = true;
  scene.add(disc);

  scene.add(new THREE.HemisphereLight('#f4f6f2', '#3a3f3b', 0.6));
  const key = new THREE.DirectionalLight('#ffffff', 2.2);
  key.position.set(radius * 2, radius * 5, radius * 2.5);
  key.target.position.copy(focus);
  key.castShadow = true;
  key.shadow.mapSize.set(2048, 2048);
  key.shadow.radius = 6;
  key.shadow.blurSamples = 16;
  key.shadow.bias = -0.0005;
  key.shadow.normalBias = radius * 0.004;
  const shadowCamera = key.shadow.camera;
  shadowCamera.left = shadowCamera.bottom = -radius * 2;
  shadowCamera.right = shadowCamera.top = radius * 2;
  shadowCamera.near = radius * 0.5;
  shadowCamera.far = radius * 12;
  scene.add(key, key.target);

  // Auto-fit: frame the bounding sphere from a three-quarter view.
  const fitDistance = radius / Math.sin(THREE.MathUtils.degToRad(camera.fov) / 2) * 1.15;
  camera.near = radius / 100;
  camera.far = radius * 100;
  camera.position.copy(focus).add(new THREE.Vector3(1, 0.65, 1.2).normalize().multiplyScalar(fitDistance));
  camera.updateProjectionMatrix();
  controls.target.copy(focus);
  controls.minDistance = radius * 0.3;
  controls.maxDistance = radius * 8;
  controls.maxPolarAngle = Math.PI * 0.495;
  controls.update();

  const wireframe = element<HTMLButtonElement>('wireframe-toggle');
  wireframe.hidden = false;
  wireframe.addEventListener('click', () => {
    const enabled = wireframe.getAttribute('aria-pressed') !== 'true';
    wireframe.setAttribute('aria-pressed', String(enabled));
    for (const mesh of meshes) {
      const materials = Array.isArray(mesh.material) ? mesh.material : [mesh.material];
      for (const material of materials) {
        if ('wireframe' in material) (material as THREE.MeshStandardMaterial).wireframe = enabled;
      }
    }
  });

  if (manifest.usdz) {
    const download = element<HTMLAnchorElement>('download-usdz');
    download.href = new URL(manifest.usdz, base).href;
    download.hidden = false;
  }

  const resize = () => {
    const { clientWidth: width, clientHeight: height } = canvas;
    if (!width || !height) return;
    renderer.setSize(width, height, false);
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
  };
  new ResizeObserver(resize).observe(canvas);
  resize();
  renderer.setAnimationLoop(() => {
    controls.update();
    renderer.render(scene, camera);
  });

  const photos = Number.isFinite(manifest.photos) ? ` · ${manifest.photos} photos` : '';
  status.value = `${manifest.name || id}${photos} · built ${formatDate(manifest.builtAt)}`;
}

const id = new URLSearchParams(location.search).get('id');
if (id) await showObject(id);
else await showList();
