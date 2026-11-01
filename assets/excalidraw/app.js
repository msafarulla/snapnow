// SnapNow's embedded Excalidraw (MIT — github.com/excalidraw/excalidraw), via the prebuilt UMD bundle.
// Renders the component full-window and exposes window.snapnow for the Flutter host, plus callHandler events.
(function () {
  function show(msg){var r=document.getElementById("root");if(r)r.innerHTML='<pre style="padding:16px;color:#b00;white-space:pre-wrap;font:13px monospace">'+msg+'</pre>';
    if(window.flutter_inappwebview)window.flutter_inappwebview.callHandler("error",String(msg));}
  var React=window.React, ReactDOM=window.ReactDOM, L=window.ExcalidrawLib;
  var missing=[]; if(!React)missing.push("React"); if(!ReactDOM)missing.push("ReactDOM"); if(!L)missing.push("ExcalidrawLib");
  if(missing.length){show("Missing globals: "+missing.join(", "));return;}
  function b64(buf){var s="",a=new Uint8Array(buf);for(var i=0;i<a.length;i+=0x8000)s+=String.fromCharCode.apply(null,a.subarray(i,i+0x8000));return btoa(s);}
  function toHost(name,p){return window.flutter_inappwebview&&window.flutter_inappwebview.callHandler(name,p);}
  function App(){
    var onApi=React.useCallback(function(api){
      window.snapnow={
        loadScene:function(json){try{var d=typeof json==="string"?JSON.parse(json):json;if(d.files)api.addFiles(Object.values(d.files));api.updateScene({elements:d.elements||[],appState:d.appState||{}});api.scrollToContent();return true;}catch(e){toHost("error",String(e));return false;}},
        addImage:function(dataUrl,w,h){try{var id="snap_"+Date.now();api.addFiles([{id:id,dataURL:dataUrl,mimeType:"image/png",created:Date.now()}]);var els=L.convertToExcalidrawElements([{type:"image",fileId:id,x:-w/2,y:-h/2,width:w,height:h}]);api.updateScene({elements:api.getSceneElements().concat(els)});api.scrollToContent(els);return true;}catch(e){toHost("error","addImage: "+e);return false;}},
        getScene:function(){return JSON.stringify({type:"excalidraw",version:2,elements:api.getSceneElements(),appState:{viewBackgroundColor:api.getAppState().viewBackgroundColor},files:api.getFiles()});},
        exportPng:function(){return L.exportToBlob({elements:api.getSceneElements(),appState:api.getAppState(),files:api.getFiles(),mimeType:"image/png",exportPadding:8}).then(function(blob){return blob.arrayBuffer();}).then(function(buf){toHost("exportPng",b64(buf));}).catch(function(e){toHost("error","exportPng: "+e);});}
      };
      toHost("ready",true);
    },[]);
    return React.createElement("div",{style:{position:"fixed",inset:0}},React.createElement(L.Excalidraw,{excalidrawAPI:onApi}));
  }
  try{ReactDOM.createRoot(document.getElementById("root")).render(React.createElement(App));}
  catch(e){show("render failed: "+(e&&e.stack?e.stack:e));}
})();
