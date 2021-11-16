'use strict';

let instantiateStreaming = WebAssembly.instantiateStreaming;
if (instantiateStreaming === undefined) {
	instantiateStreaming = (source, imports) => {
		return source.then(res =>
			res.arrayBuffer()
		).then(buf =>
			WebAssembly.instantiate(buf, imports)
		);
	}
}

const slimy_promise = instantiateStreaming(fetch("slimy.wasm"), {slimy: {
	consoleLog(ptr, len) { // For debugging purposes
		const buf = new Uint8Array(slimy.memory.buffer, ptr, len);
		const str = new TextDecoder('utf-8').decode(buf);
		postMessage({
			type: "log",
			msg: str,
		});
	},

	resultCallback(x, z, count) {
		postMessage({
			type: "result",
			x: x,
			z: z,
			count: count,
		});
	},
}}).then(result => {
	slimy = result.instance.exports;
});
let slimy;

// Yield to the event loop
const tickEventLoop = () => {
	return new Promise(resolve => {
		const chan = new MessageChannel();
		chan.port1.onmessage = resolve;
		chan.port2.postMessage(undefined);
	});
};

let cancel;
const searchAsync = async params => {
	cancel = false;

	const searcher = slimy.searchInit(
		params.seed,
		params.threshold,
		params.x0,
		params.x1,
		params.z0,
		params.z1,
	);

	while (!cancel && slimy.searchStep(searcher)) {
		postMessage({
			type: "progress",
			progress: slimy.searchProgress(searcher),
		});
		await tickEventLoop();
	}

	slimy.searchDeinit(searcher);

	if (cancel) {
		cancel = false;
		return false;
	}

	return true;
};

onmessage = e => {
	if (e.data === "cancel") {
		cancel = true
	} else {
		slimy_promise.then(async () => {
			const start = performance.now();
			const ok = await searchAsync(e.data);
			const end = performance.now();

			if (ok) {
				postMessage({
					type: "finish",
					time: end - start,
				});
			} else {
				postMessage({
					type: "cancel",
				});
			}
		});
	}
};
