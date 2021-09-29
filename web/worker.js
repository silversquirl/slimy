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

	resultCallback(x, y, count) {
		postMessage({
			type: "result",
			x: x,
			y: y,
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

const searchAsync = async params => {
	const searcher = slimy.searchInit(params.seed, params.range, params.threshold);
	while (slimy.searchStep(searcher)) {
		postMessage({
			type: "progress",
			progress: slimy.searchProgress(searcher),
		});
		await tickEventLoop();
	}
	slimy.searchDeinit(searcher);
};

onmessage = function(e) {
	slimy_promise.then(async () => {
		// TODO: task cancellation

		const start = performance.now();
		await searchAsync(e.data);
		const end = performance.now();

		postMessage({
			type: "finish",
			time: end - start,
		});
	});
};
