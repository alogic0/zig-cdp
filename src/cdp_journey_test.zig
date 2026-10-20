const std = @import("std");
const cdp = @import("cdp.zig");
const J = cdp.journey;

test "owned browser shutdown removes the profile after process exit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    const browser = try J.Browser.start(arena.allocator(), io);
    browser.stop();
    browser.stop();
    try std.testing.expect(browser.child.pid == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, browser.profile, .{}));
    try std.Io.sleep(io, .fromMilliseconds(100), .awake);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, browser.profile, .{}));
}

test "browser cleanup preserves an unrelated child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var peer = try @import("process").Child.spawn(arena.allocator(), std.testing.io, .{ .argv = &.{ "/bin/sleep", "30" } });
    defer peer.deinit();
    const browser = try J.Browser.start(arena.allocator(), std.testing.io);
    browser.stop();
    try std.testing.expect(try peer.poll() == null);
}

test "saved profile uses the startup tab and survives workspace cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var random: [12]u8 = undefined;
    io.random(&random);
    const profile = try a.print("/tmp/cdp-saved-test-{s}", .{std.fmt.bytesToHex(random, .lower)});
    try std.Io.Dir.cwd().createDir(io, profile, .fromMode(0o700));
    defer std.Io.Dir.cwd().deleteTree(io, profile) catch {};
    const marker = try a.print("{s}/keep", .{profile});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "caller data" });
    const browser = try J.Browser.startWithOptions(a, io, .{ .user_data_dir = profile });
    defer browser.stop();
    const targets = try browser.client.listTargets();
    var startup: []const u8 = "";
    for (targets) |target| {
        if (std.mem.eql(u8, target.target_type, "page") and std.mem.eql(u8, target.url, "about:blank")) startup = target.id;
    }
    try std.testing.expect(startup.len > 0);
    const isolated = try browser.page(&.{});
    defer isolated.close();
    const saved = try browser.profilePage(&.{});
    defer saved.close();
    try std.testing.expectEqualStrings(startup, saved.target);
    try std.testing.expect(!std.mem.eql(u8, saved.target, isolated.target));
    saved.close();
    isolated.close();
    browser.stop();
    browser.stop();
    try std.testing.expect(browser.child.pid == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, browser.workspace, .{}));
    const data = try std.Io.Dir.cwd().readFileAlloc(io, marker, a, .limited(100));
    try std.testing.expectEqualStrings("caller data", data);
}

test "raw evaluation escapes controls and parsed replies own their strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const browser = try J.Browser.start(arena.allocator(), std.testing.io);
    defer browser.stop();
    const client = cdp.CdpClient.init(std.testing.allocator, std.testing.io, browser.client.port);
    const target = try client.newTarget("about:blank");
    defer target.deinit(std.testing.allocator);
    defer client.closeTarget(target.id) catch {};
    var socket = try client.connectWs(target.web_socket_debugger_url);
    defer socket.close();
    const reply = try socket.evaluateJson("'literal tab:\t'");
    defer reply.deinit();
    try std.testing.expectEqualStrings("literal tab:\t", J.str(J.field(J.field(J.field(reply.value, "result"), "result"), "value")));
}

test "observed response headers are case insensitive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: J.Request = .{ .id = "1", .url = "http://fixture.invalid/", .method = "GET", .post_data = "", .headers = try J.parse(arena.allocator(), "{\"X-Request-Id\":\"receipt\",\"Content-Type\":\"application/json\"}") };
    try std.testing.expectEqualStrings("receipt", J.str(r.header("x-request-id")));
    try std.testing.expectEqualStrings("application/json", J.str(r.header("CONTENT-TYPE")));
    try std.testing.expect(r.header("missing") == .null);
}

test "CDP exact numeric reply identity" {
    try std.testing.expectEqual(@as(?u32, 10), try cdp.WsSession.responseId(std.testing.allocator, "{\"id\":10,\"result\":{\"id\":1}}"));
    try std.testing.expectEqual(@as(?u32, null), try cdp.WsSession.responseId(std.testing.allocator, "{\"method\":\"Network.responseReceived\",\"params\":{\"id\":1}}"));
    try std.testing.expectError(error.InvalidProtocolReply, cdp.WsSession.responseId(std.testing.allocator, "{\"id\":\"1\"}"));
}

test "stale interception callbacks keep the browser session usable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const browser = try J.Browser.start(arena.allocator(), std.testing.io);
    defer browser.stop();
    const p = try browser.page(&.{"http://fixture.invalid"});
    defer p.close();
    for ([_][]const u8{ "http://fixture.invalid/canceled", "https://outside.invalid/canceled" }) |url| {
        const raw = try J.json(arena.allocator(), .{ .method = "Fetch.requestPaused", .params = .{ .requestId = "stale-fixture-id", .request = .{ .url = url } } });
        try p.socket.event_handler.?(p.socket.event_context.?, &p.socket, raw);
        try std.testing.expect(!p.socket.failed);
        try std.testing.expect(J.boolean(try p.eval("true")));
    }
    try std.testing.expect(J.boolean(try p.eval("fetch('https://outside.invalid/probe').then(()=>false,()=>true)")));
}

test "owned CDP actual input upload download isolation and origin denial" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const browser = try J.Browser.start(a, io);
    defer browser.stop();
    const p = try browser.page(&.{});
    defer p.close();
    try std.testing.expectEqual(@as(i64, 1280), J.number(try p.eval("innerWidth")));
    try std.testing.expectEqual(@as(i64, 720), J.number(try p.eval("innerHeight")));
    const mark = try p.mark();
    _ = try p.eval("Promise.all([fetch('data:text/plain,first-body').then(r=>r.text()),fetch('data:text/plain,second-body').then(r=>r.text())])");
    try p.pump();
    var bodies: usize = 0;
    for (p.requests.items[mark..]) |r| {
        if (std.mem.startsWith(u8, r.url, "data:text/plain,")) {
            try std.testing.expect(r.finished and r.body != null);
            try std.testing.expectEqualStrings(r.url["data:text/plain,".len..], r.body.?);
            bodies += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), bodies);
    _ = try p.eval("document.body.innerHTML='<label>Name<input id=entry></label><input type=file id=file><button id=act>Download</button><button disabled>Disabled</button>';window.trusted=[];document.addEventListener('input',e=>trusted.push(e.isTrusted));document.querySelector('#act').onclick=()=>{const a=document.createElement(\"a\");a.href=URL.createObjectURL(new Blob([\"exact,bytes\\r\\n\"]));a.download=\"fixture.csv\";a.click()};true");
    try p.label("Name").fill("native input");
    try std.testing.expect(J.boolean(try p.eval("document.querySelector('#entry').value==='native input'&&trusted.length===1&&trusted[0]")));
    const owned = try a.print("{s}/upload.csv", .{browser.profile});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = owned, .data = "header\nvalue\n" });
    _ = try p.eval("const file=document.querySelector('#file');file.disabled=true;file.hidden=true;window.fileReady=false;file.onchange=()=>fileReady=!file.disabled;setTimeout(()=>file.disabled=false,200);true");
    try p.css("#file").file(owned);
    try std.testing.expect(J.boolean(try p.eval("fileReady")));
    try std.testing.expectEqualStrings("header\nvalue\n", J.str(try p.eval("document.querySelector('#file').files[0].text()")));
    const download = try p.download(p.role(.{ .role = "button", .name = "Download" }), try a.print("{s}/result.csv", .{browser.profile}));
    try std.testing.expectEqualStrings("fixture.csv", J.str(J.field(download, "filename")));
    try std.testing.expectEqualStrings("exact,bytes\r\n", J.str(J.field(download, "csv")));
    _ = try p.eval("document.body.insertAdjacentHTML('beforeend','<section hidden><button>Download</button></section>');true");
    try std.testing.expectEqual(@as(usize, 1), try p.role(.{ .role = "button", .name = "Download" }).count());
    _ = try p.eval("document.body.insertAdjacentHTML('beforeend','<div style=\"display:contents\"><p>Estimated amount: $0.02 (reference)</p></div>');true");
    try std.testing.expectEqual(@as(usize, 1), try p.textRegex("Estimated amount: \\$0.02").count());
    _ = try p.eval("document.body.insertAdjacentHTML('beforeend','<button id=shift>Moving control</button>');window.movedClick=false;const shift=document.querySelector('#shift');shift.onmouseenter=()=>shift.style.marginLeft='160px';shift.onclick=()=>movedClick=true;true");
    try p.role(.{ .role = "button", .name = "Moving control" }).click();
    try std.testing.expect(J.boolean(try p.eval("movedClick")));
    _ = try p.eval("window.onbeforeunload=e=>{e.preventDefault();e.returnValue='';};true");
    try p.reload();
    _ = try p.eval("document.body.innerHTML='<button>Download</button><button disabled>Disabled</button>';true");
    p.timeout_ms = 100;
    try std.testing.expectError(error.ElementNotActionable, p.role(.{ .role = "button", .name = "Disabled" }).click());
    _ = try p.eval("document.body.insertAdjacentHTML('beforeend','<div style=\"position:fixed;inset:0;z-index:999\"></div>');true");
    try std.testing.expectError(error.ElementNotActionable, p.role(.{ .role = "button", .name = "Download" }).click());
    try std.testing.expect(J.boolean(try p.eval("fetch('https://outside.invalid/probe').then(()=>false,()=>true)")));
    _ = try browser.command("Storage.setCookies", .{ .browserContextId = p.context, .cookies = .{.{ .name = "owned", .value = "one", .domain = "fixture.invalid", .path = "/" }} });
    const peer = try browser.page(&.{});
    defer peer.close();
    const cookies = try browser.command("Storage.getCookies", .{ .browserContextId = peer.context });
    try std.testing.expectEqual(@as(usize, 0), J.field(cookies, "cookies").array.items.len);
}
