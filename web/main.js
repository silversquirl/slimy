(function() {
	'use strict';

	const initUi = (slimy) => {
	    console.log("searching...");
	    const start = performance.now();
	    slimy.search(1n, 1000, 41);
	    const end = performance.now();
	    console.log(`done in ${end - start}ms`);
	};

	let instantiateStreaming = WebAssembly.instantiateStreaming;
	if (instantiateStreaming === undefined) {
		// Specialized polyfill specifically for our needs
		instantiateStreaming = (source, imports) => {
			return source.then(res =>
				res.arrayBuffer()
			).then(buf =>
				WebAssembly.instantiate(buf, imports)
			);
		}
	}

	instantiateStreaming(fetch("slimy.wasm"), {slimy: {
		searchCallback(x, y, count) {
			console.log(x, y, count);
		}
	}}).then(result => {
		initUi(result.instance.exports);
	});
})();
