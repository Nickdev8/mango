<script lang="ts">
	import { onMount, onDestroy } from 'svelte';
	import io, { Socket } from 'socket.io-client';

	interface BodyState {
		id: string;
		x: number;
		y: number;
		angle: number;
		width: number;
		height: number;
		image?: string;
	}

	let canvas: HTMLCanvasElement;
	let ctx: CanvasRenderingContext2D;
	let socket: Socket;

	let cursorImg: HTMLImageElement;
	const cursorSize = 32;

	interface CursorHuesMap {
		[id: string]: number;
	}
	const cursorHues: CursorHuesMap = {};

	interface MousePosition {
		x: number;
		y: number;
	}
	interface MousePositionsMap {
		[id: string]: MousePosition;
	}
	let mousePositions: MousePositionsMap = {};

	let canvasWidth = 2048;
	let canvasHeight = 1024; // 2:1 ratio
	let objects: Record<string, BodyState> = {};

	let dragging = false;
	let dragId: string | null = null;
	let dragOffset = { x: 0, y: 0 }; // Offset from mouse to object center
	const RADIUS = 20;
	let spriteCache: Record<string, HTMLImageElement> = {};

	// Add mouse movement tracking for throwing
	let lastMousePos = { x: 0, y: 0 };
	let mouseVelocity = { x: 0, y: 0 };
	let lastMouseTime = 0;

	let lobbyCode: string | null = null;
	let joinedPhysics = false;

	// Performance optimizations
	let animationFrameId: number | null = null;
	let lastDrawTime = 0;
	const TARGET_FPS = 60;
	const FRAME_TIME = 1000 / TARGET_FPS;

	// Disable excessive logging for better performance
	const log = (...args: any[]) => {}; // Disable all logging
	// const log = (...args: any[]) => console.log(...args); // Uncomment for debugging

	function colorForId(id: string): string {
		let hash = 0;
		for (let i = 0; i < id.length; i++) {
			hash = (hash * 31 + id.charCodeAt(i)) | 0;
		}
		const hue = (hash >>> 0) % 360;
		return `hsl(${hue},100%,50%)`;
	}

	function makeCursorDataURL(color: string): string {
		const svg = `
     <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 32 32">
       <path d="M1,1 L31,16 L1,31 Z" fill="${color}" stroke="black" stroke-width="1"/>
     </svg>
   `.trim();
		return `data:image/svg+xml,${encodeURIComponent(svg)}`;
	}

	function handleWindowMousemove(e: MouseEvent): void {
		if (!canvas) return;
		const { x, y } = transformMouseToCanvas(e.clientX, e.clientY);
		const currentTime = performance.now();

		// Calculate mouse velocity (pixels per second)
		if (lastMouseTime > 0) {
			const deltaTime = (currentTime - lastMouseTime) / 1000; // Convert to seconds
			if (deltaTime > 0) {
				mouseVelocity.x = (x - lastMousePos.x) / deltaTime;
				mouseVelocity.y = (y - lastMousePos.y) / deltaTime;
			}
		}

		lastMousePos = { x, y };
		lastMouseTime = currentTime;

		try {
			if (x >= 0 && y >= 0 && x <= canvas.width && y <= canvas.height) {
				safeEmit('movemouse', { x, y });
			} else {
				safeEmit('mouseLeave');
			}
			if (dragging && dragId) {
				safeEmit('drag', { x, y });
			}
		} catch (err) {
			console.error('[handleWindowMousemove] emit error:', err);
		}
	}

	function handleWindowMouseleave(): void {
		safeEmit('mouseLeave');
	}

	function handleWindowMouseup(): void {
		if (dragging && dragId) {
			// Calculate throw velocity (reduced power)
			const throwVelocity = {
				x: mouseVelocity.x * 0.3, // Reduce power to 30%
				y: mouseVelocity.y * 0.3
			};
			
			safeEmit('endDrag', { velocity: throwVelocity });
			dragging = false;
			dragId = null;
			
			// Reset velocity tracking
			mouseVelocity = { x: 0, y: 0 };
			lastMouseTime = 0;
		}
	}

	function handleCanvasMousedown(e: MouseEvent): void {
		const { x: mx, y: my } = transformMouseToCanvas(e.clientX, e.clientY);
		
		let hit = false;
		for (const id in objects) {
			const o = objects[id];
			const dx = mx - o.x;
			const dy = my - o.y;
			
			// Use rectangular hit detection for objects with width/height, circular for others
			let isHit = false;
			if (o.width && o.height) {
				// Rectangular hit detection - check if mouse is within the object bounds
				const halfWidth = o.width / 2;
				const halfHeight = o.height / 2;
				isHit = Math.abs(dx) <= halfWidth && Math.abs(dy) <= halfHeight;
			} else {
				// Circular hit detection for objects without explicit dimensions
				isHit = dx * dx + dy * dy <= RADIUS * RADIUS;
			}
			
			if (isHit) {
				hit = true;
				dragging = true;
				dragId = id;
				// Calculate offset from mouse to object center
				dragOffset.x = dx;
				dragOffset.y = dy;
				
				// Initialize mouse tracking for throwing
				lastMousePos = { x: mx, y: my };
				lastMouseTime = performance.now();
				mouseVelocity = { x: 0, y: 0 };
				
				safeEmit('startDrag', { id, x: mx, y: my });
				break;
			}
		}
		if (!hit && dragging) {
			safeEmit('endDrag');
			dragging = false;
			dragId = null;
		}
	}

	function handleCanvasMousemove(e: MouseEvent): void {
		if (!dragging) return;
		const { x: mx, y: my } = transformMouseToCanvas(e.clientX, e.clientY);
		safeEmit('drag', { x: mx, y: my });
	}

	function draw(): void {
		ctx.clearRect(0, 0, canvas.width, canvas.height);

		// Draw simple background
		ctx.fillStyle = '#f8f6f0';
		ctx.fillRect(0, 0, canvas.width, canvas.height);

		// Draw objects
		for (const id in objects) {
			const o = objects[id];
			ctx.save();
			ctx.translate(o.x, o.y);
			ctx.rotate(o.angle);
			
			if (o.image) {
				let img = spriteCache[id];
				if (!img) {
					img = new Image();
					img.src = o.image;
					spriteCache[id] = img;
					img.onload = () => {
						requestAnimationFrame(draw);
					};
					img.onerror = (e) => console.error('[draw] Image load error for', id, e);
				}
				ctx.drawImage(img, -o.width / 2, -o.height / 2, o.width, o.height);
			} else {
				// Draw simple circle for better performance
				ctx.fillStyle = 'blue';
				ctx.beginPath();
				ctx.arc(0, 0, RADIUS, 0, Math.PI * 2);
				ctx.fill();
			}
			
			ctx.restore();
		}

		// Draw cursors
		for (const clientId in mousePositions) {
			const pos = mousePositions[clientId]!;
			const hue = cursorHues[clientId]!;

			ctx.save();
			ctx.filter = `hue-rotate(${hue}deg)`;
			ctx.drawImage(
				cursorImg,
				pos.x - 14, // Hotspot X offset
				pos.y - 8,  // Hotspot Y offset
				cursorSize,
				cursorSize
			);
			ctx.restore();
		}

		ctx.filter = 'none';

		// Schedule next frame
		requestAnimationFrame(draw);
	}

	onMount(() => {
		// Set canvas to 2:1 aspect ratio (2048x1024)
		canvasWidth = 2048;
		canvasHeight = 1024; // 2:1 ratio
		canvas.width = canvasWidth;
		canvas.height = canvasHeight;
		canvas.style.width = '100%';
		canvas.style.height = 'auto';

		// Extract lobby code from URL
		const params = new URLSearchParams(window.location.search);
		lobbyCode = params.get('lobby');
		if (!lobbyCode) {
			alert('No lobby code in URL!');
			return;
		}

		cursorImg = new Image();
		cursorImg.src = '/images/cursor.svg';
		cursorImg.onload = () => {
			// Start the render loop
			animationFrameId = requestAnimationFrame(draw);
		};

		if (!canvas) {
			console.error('[onMount] canvas ref not set!');
			return;
		}
		ctx = canvas.getContext('2d')!;
		socket = io(location.origin, { transports: ['websocket'], timeout: 10000 });

		socket.on('connect', () => {
			const localId = socket.id!;
			cursorHues[localId] = Math.floor(Math.random() * 360);
			// Join the physics lobby
			socket.emit('joinPhysics', { lobby: lobbyCode });
		});

		socket.on('joinedPhysics', () => {
			joinedPhysics = true;
		});

		socket.on('connect_error', (err) => {
			console.error('[socket] connect_error:', err);
		});
		socket.on('disconnect', (reason) => {
			console.warn('[socket] disconnect:', reason);
		});

		// update
		socket.on('state', (payload: { bodies: BodyState[]; anchors: { x: number; y: number }[] }) => {
			// Update all objects from server
			payload.bodies.forEach((o) => {
				objects[o.id] = o;
			});
		});

		socket.on('mouseMoved', (payload: { id: string; x: number; y: number }) => {
			const { id, x, y } = payload;

			if (id === socket.id) {
				return;
			}

			mousePositions[id] = { x, y };

			if (cursorHues[id] === undefined) {
				cursorHues[id] = Math.floor(Math.random() * 360);
			}
		});

		socket.on('mouseRemoved', ({ id }: { id: string }) => {
			delete mousePositions[id];
		});

		window.addEventListener('mousemove', handleWindowMousemove);
		window.addEventListener('mouseleave', handleWindowMouseleave);
		window.addEventListener('mouseup', handleWindowMouseup);
	});

	onDestroy(() => {
		window.removeEventListener('mousemove', handleWindowMousemove);
		window.removeEventListener('mouseleave', handleWindowMouseleave);
		window.removeEventListener('mouseup', handleWindowMouseup);
		if (animationFrameId) {
			cancelAnimationFrame(animationFrameId);
		}
		socket.disconnect();
	});

	// --- Wrap socket emits to only send after joinedPhysics ---
	function safeEmit(event: string, data?: any) {
		if (joinedPhysics) {
			socket.emit(event, data);
		}
	}

	// Coordinate transformation function to ensure consistent coordinates
	function transformMouseToCanvas(clientX: number, clientY: number): { x: number; y: number } {
		if (!canvas) return { x: clientX, y: clientY };
		
		const rect = canvas.getBoundingClientRect();
		const scaleX = canvas.width / rect.width;
		const scaleY = canvas.height / rect.height;
		
		const x = (clientX - rect.left) * scaleX;
		const y = (clientY - rect.top) * scaleY;
		
		// Clamp coordinates to canvas bounds
		const clampedX = Math.max(0, Math.min(canvas.width, x));
		const clampedY = Math.max(0, Math.min(canvas.height, y));
		
		return { x: clampedX, y: clampedY };
	}
</script>

<div class="game-container">
	<div class="canvas-wrapper">
		<canvas
			bind:this={canvas}
			width={canvasWidth}
			height={canvasHeight}
			style="cursor:url(''/images/cursor.svg') 14 8, auto"
			on:mousedown={handleCanvasMousedown}
			on:mousemove={handleCanvasMousemove}
		></canvas>
	</div>
	
	<!-- Hand-drawn style UI overlay -->
	<div class="ui-overlay">
		<div class="info-panel">
			<div class="info-item">
				<span class="info-label">🎮 Lobby:</span>
				<span class="info-value">{lobbyCode}</span>
			</div>
			<div class="info-item">
				<span class="info-label">👥 Players:</span>
				<span class="info-value">{Object.keys(mousePositions).length + 1}</span>
			</div>
		</div>
	</div>
</div>

<style>
	.game-container {
		position: relative;
		width: 100vw;
		height: 100vh;
		background: linear-gradient(135deg, #f5f7fa 0%, #c3cfe2 100%);
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		overflow: hidden;
		margin: 0;
		padding: 0;
	}

	.canvas-wrapper {
		position: relative;
		width: 100%;
		height: 100vh;
		display: flex;
		justify-content: center;
		align-items: center;
		padding: 20px;
		box-sizing: border-box;
		overflow: hidden;
		/* Ensure the wrapper respects the 2:1 aspect ratio */
		max-width: calc((100vh - 40px) * 2);
	}

	canvas {
		background-color: #f8f6f0;
		max-width: calc(100vw - 40px);
		max-height: calc(100vh - 40px);
		width: 100%;
		height: auto;
		display: block;
		border: 3px solid #8b7355;
		border-radius: 15px;
		box-shadow: 
			0 10px 30px rgba(0,0,0,0.2),
			0 0 0 1px rgba(139, 115, 85, 0.3);
		/* Maintain 2:1 aspect ratio */
		aspect-ratio: 2/1;
		object-fit: contain;
	}

	.ui-overlay {
		position: absolute;
		top: 20px;
		left: 20px;
		right: 20px;
		pointer-events: none;
		z-index: 10;
	}

	.info-panel {
		background: rgba(255, 255, 255, 0.95);
		border: 3px solid #8b7355;
		border-radius: 15px;
		padding: 15px 20px;
		box-shadow: 
			0 5px 15px rgba(0,0,0,0.1),
			0 0 0 1px rgba(139, 115, 85, 0.2);
		display: inline-block;
		pointer-events: none;
	}

	.info-item {
		display: flex;
		align-items: center;
		gap: 10px;
		margin-bottom: 8px;
		font-family: 'Comic Neue', cursive;
		font-size: 1rem;
	}

	.info-item:last-child {
		margin-bottom: 0;
	}

	.info-label {
		font-weight: 600;
		color: #5d4e37;
	}

	.info-value {
		font-weight: 700;
		color: #8b7355;
		background: #f0e6d2;
		padding: 2px 8px;
		border-radius: 8px;
		border: 1px solid #d4c4a8;
	}

	/* Hand-drawn style decorations */
	.game-container::before {
		content: '';
		position: absolute;
		top: 10px;
		right: 10px;
		width: 60px;
		height: 60px;
		background: url('data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><circle cx="50" cy="50" r="45" fill="none" stroke="%238b7355" stroke-width="3" stroke-dasharray="5,5"/><circle cx="50" cy="50" r="25" fill="none" stroke="%238b7355" stroke-width="2"/></svg>') no-repeat center;
		opacity: 0.3;
		pointer-events: none;
	}

	.game-container::after {
		content: '';
		position: absolute;
		bottom: 10px;
		right: 10px;
		width: 40px;
		height: 40px;
		background: url('data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><path d="M20,80 L80,80 L80,20 L20,20 Z" fill="none" stroke="%238b7355" stroke-width="2" stroke-dasharray="3,3"/></svg>') no-repeat center;
		opacity: 0.3;
		pointer-events: none;
	}

	@media (max-width: 768px) {
		.ui-overlay {
			top: 10px;
			left: 10px;
			right: 10px;
		}

		.info-panel {
			padding: 10px 15px;
		}

		.info-item {
			font-size: 0.9rem;
		}

	}
</style>