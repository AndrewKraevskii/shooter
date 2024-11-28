const std = @import("std");

const rgui = @import("raygui");
const rl = @import("raylib");

pub fn cameraForward(camera: rl.Camera3D) rl.Vector3 {
    return camera.target.subtract(camera.position).normalize();
}

pub fn toMap(vec: rl.Vector3) rl.Vector2 {
    return .{
        .x = vec.x,
        .y = vec.z,
    };
}

pub fn toWorld(vec: rl.Vector2) rl.Vector3 {
    return .{
        .x = vec.x,
        .z = vec.y,
        .y = 0.5,
    };
}

pub fn findEmptySpotOnAMap(random: std.Random, map: rl.Image, max_attempts: ?u32) ?rl.Vector2 {
    const size: u31 = @max(0, map.width * map.height);
    const width: u31 = @max(0, map.width);
    if (size == 0) return null;
    for (0..max_attempts orelse std.math.maxInt(usize)) |_| {
        const num = random.intRangeLessThan(u31, 0, size);

        if (isMapCellEmpty(map, .{ num % width, num / width })) return .{
            .x = @floatFromInt(num % width),
            .y = @floatFromInt(num / width),
        };
    } else return null;
}

pub fn isMapCellEmpty(map: rl.Image, coord: [2]i32) bool {
    if (coord[0] < 0 or
        coord[1] < 0 or
        coord[0] > map.width or
        coord[1] > map.height) return false;
    const color = map.getColor(coord[0], coord[1]);

    return color.r == 0;
}

pub fn checkCollisionWithMap(map: rl.Image, start: rl.Vector2, end: rl.Vector2, step_size: f32) bool {
    if (start.x < 0 or start.x >= @as(f32, @floatFromInt(map.width)) or start.y < 0 or start.y >= @as(f32, @floatFromInt(map.height))) {
        return true;
    }
    if (end.x < 0 or end.x >= @as(f32, @floatFromInt(map.width)) or end.y < 0 or end.y >= @as(f32, @floatFromInt(map.height))) {
        return true;
    }
    const step = end.subtract(start).normalize().scale(step_size);
    var point = start;
    const times: usize = @max(1, @as(usize, @intFromFloat(end.distance(start) / step_size)));
    var i: usize = 0;
    std.debug.assert(times > 0);
    while (i < times) : ({
        point = point.add(step);
        i += 1;
    }) {
        if (!isMapCellEmpty(map, .{
            @intFromFloat(point.x),
            @intFromFloat(point.y),
        })) {
            return true;
        }
    }
    return false;
}

pub fn inputDirection() rl.Vector2 {
    var keyboard_vel = rl.Vector2.zero();
    if (rl.isKeyDown(.key_w)) {
        keyboard_vel.x += 1;
    }
    if (rl.isKeyDown(.key_s)) {
        keyboard_vel.x -= 1;
    }
    if (rl.isKeyDown(.key_a)) {
        keyboard_vel.y -= 1;
    }
    if (rl.isKeyDown(.key_d)) {
        keyboard_vel.y += 1;
    }
    return keyboard_vel.normalize();
}

const bullet_speed = 10;
const player_spawn_delay = 0.2;
const enemy_spawn_delay = 2;
const respawn_delay = 5;
const player_speed = 4;
const player_radius = 0.3;
const enemy_radius = 0.3;
const camera_rotation_speed = 0.03;
const enemy_from_player_spawn_distance = 5;
const monsters_move = true;
const invulnerability = false;

const Particle = struct {
    type: enum {
        bullet,
        explosion,
        trail,
    },
    size: f32,
    pos: rl.Vector3,
    vel: rl.Vector3,
    ttl: f32,
};

const GameState = struct {
    random: std.Random,
    camera: rl.Camera,
    spawn_cooldown: f32 = 0,
    respawn_cooldown: f32 = 0,
    enemy_spawn_cooldown: f32 = 0,
    particles: std.BoundedArray(Particle, 0x1000) = .{},
    mode: enum {
        pause,
        playing,
    } = .playing,
    player_state: enum {
        dead,
        alive,
        won,
    } = .alive,
    enemies: std.BoundedArray(Enemy, 0x30) = .{},
    enemies_killed: u32 = 0,

    fn init(random: std.Random, map: rl.Image) GameState {
        var game: GameState = undefined;

        const player_starting_pos = (findEmptySpotOnAMap(random, map, 100) orelse @panic("cant file place on map for player")).addValue(0.5);
        std.debug.print("{any}\n", .{player_starting_pos});
        game.camera.position = .{
            .x = player_starting_pos.x,
            .z = player_starting_pos.y,
            .y = 0.5,
        };

        game.camera.target = game.camera.position.add(.{
            .x = (random.float(f32) * 2 - 1),
            .z = (random.float(f32) * 2 - 1),
            .y = 0,
        });
        game.camera.up = .init(0, 1, 0);
        game.camera.fovy = 90;
        game.camera.projection = .camera_perspective;

        game.mode = .playing;
        game.player_state = .alive;

        game.particles = .{};
        game.enemies = .{};
        game.enemies.appendAssumeCapacity(.{
            .pos = (findEmptySpotOnAMap(random, map, null) orelse @panic("Cant find spot on a map")).addValue(0.5),
            .animation_count = 4,
            .animation_index = 0,
        });
        game.enemies_killed = 0;
        game.random = random;
        return game;
    }
};

const Enemy = struct {
    pos: rl.Vector2,
    animation_count: u8,
    animation_index: u8,
    projectile_cooldown: f32 = 2,
    projectile_delay: f32 = 2,
    movement_cooldown: f32 = 5,
    movement_delay: f32 = 5,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const screenWidth = 800;
    const screenHeight = 450;

    rl.setConfigFlags(.{
        .window_resizable = true,
        .msaa_4x_hint = true,
    });
    rl.initWindow(screenWidth, screenHeight, "Explosion shooter");
    rl.setExitKey(.key_null);
    rgui.guiSetStyle(.default, 16, 25);
    rgui.guiSetStyle(.default, 1, @bitCast(rl.Color.white));
    rgui.guiSetStyle(.default, 2, @bitCast(@as(u32, 0xaaAAaaFF)));
    rl.disableCursor();
    defer rl.closeWindow();

    rl.initAudioDevice();
    defer rl.closeAudioDevice();
    rl.setMasterVolume(0.1); // rl.setTargetFPS(60);

    var random_impl = std.Random.DefaultPrng.init(0);
    const random = random_impl.random();
    const map = rl.loadImage("res/cubicmap.png");

    var game = GameState.init(
        random,
        map,
    );

    const rocket_sound = rl.loadSound("res/rocket.wav");
    rl.setSoundVolume(rocket_sound, 0.5);
    const explosion_sound = rl.loadSound("res/explosion.wav");
    rl.setSoundVolume(explosion_sound, 0.5);
    const texture = rl.loadTexture("res/cubicmap_atlas.png"); // Load map texture
    const enemy_sprite = rl.loadTexture("res/monster.png");
    const screams = [_]rl.Sound{
        rl.loadSound("res/scream1.wav"),
        rl.loadSound("res/scream2.wav"),
    };

    const map_scale = 10;
    const map_texture = rl.loadTextureFromImage(map);
    const mesh = rl.genMeshCubicmap(map, .one());
    const model = rl.loadModelFromMesh(mesh);

    model.materials[0].maps[@intFromEnum(rl.MaterialMapIndex.material_map_albedo)].texture = texture; // Set map diffuse texture
    const player_respawn_delay = 3;

    const enemies_killed_goal = 30;

    _ = arena.reset(.retain_capacity);
    var potential_spawn_spots = std.ArrayListUnmanaged(rl.Vector2).empty;
    while (!rl.windowShouldClose()) {
        if (game.mode == .playing and game.player_state != .won) {
            if (game.player_state == .alive) { // update player movement
                const delta = rl.getMouseDelta();
                rl.updateCameraPro(&game.camera, .zero(), rl.Vector3.init(
                    delta.x,
                    delta.y,
                    0,
                ).scale(camera_rotation_speed), 0);

                const keyboard_direction = inputDirection();

                const camera_forward = cameraForward(game.camera);
                const camera_forward_2d = toMap(camera_forward).normalize();
                const camera_right = rl.Vector2{ .x = -camera_forward_2d.y, .y = camera_forward_2d.x };

                const direction_2d = camera_forward_2d.scale(keyboard_direction.x)
                    .add(camera_right.scale(keyboard_direction.y));
                const walk_distance_this_frame = rl.getFrameTime() * player_speed;
                var dir = rl.Vector3{ .x = direction_2d.x, .y = 0, .z = direction_2d.y };
                const new_direction = for (0..3) |_| {
                    const collision = rl.getRayCollisionMesh(
                        .{
                            .position = game.camera.position,
                            .direction = dir,
                        },
                        mesh,
                        .translate(0.5, 0, 0.5),
                    );
                    const distance_to_wall = if (collision.hit) collision.distance else 100000;

                    const max_wall_dist = player_radius;
                    dir =
                        if (distance_to_wall - max_wall_dist < walk_distance_this_frame)
                        dir.subtract(rl.math.vector3Project(
                            dir,
                            collision.normal,
                        ))
                    else
                        break dir;
                } else unreachable;
                const camera_movement = new_direction.scale(walk_distance_this_frame);
                game.camera.position = game.camera.position.add(camera_movement);
                game.camera.target = game.camera.target.add(camera_movement);
                std.log.debug("world : {d}x{d}", .{ game.camera.position.x, game.camera.position.z });
                std.log.debug("map   : {d}x{d}", .{ toMap(game.camera.position).x, toMap(game.camera.position).y });
            } else {
                game.respawn_cooldown -= rl.getFrameTime();
                if (game.respawn_cooldown < 0) blk: {
                    game.player_state = .alive;

                    for (game.enemies.slice()) |*enemy| {
                        enemy.projectile_cooldown = player_respawn_delay;
                    }

                    const new_player_pos = (findEmptySpotOnAMap(random, map, 100) orelse break :blk).addValue(0.5);
                    game.camera.position = .{
                        .x = new_player_pos.x,
                        .z = new_player_pos.y,
                        .y = 0.5,
                    };
                    game.camera.target = game.camera.position.add(.{
                        .x = (random.float(f32) * 2 - 1),
                        .z = (random.float(f32) * 2 - 1),
                        .y = 0,
                    });
                }
            }
            { // spawn enemy
                game.enemy_spawn_cooldown -= rl.getFrameTime();
                if (game.enemy_spawn_cooldown < 0) blk: {
                    game.enemy_spawn_cooldown = enemy_spawn_delay;
                    const spawn_position = for (0..10) |_| {
                        const potential_spawn_point = (findEmptySpotOnAMap(random, map, 100) orelse break :blk).addValue(0.5);

                        if (checkCollisionWithMap(map, potential_spawn_point, toMap(game.camera.position), 0.01) and
                            checkCollisionWithMap(map, potential_spawn_point.add(.{ .x = 0.023342, .y = -0.01 }), toMap(game.camera.position), 0.01))
                        {
                            break potential_spawn_point;
                        } else {
                            try potential_spawn_spots.append(arena.allocator(), potential_spawn_point);
                        }
                    } else break :blk;

                    game.enemies.append(.{
                        .pos = spawn_position,
                        .animation_count = 4,
                        .animation_index = 0,
                    }) catch {};
                }
            }
            { // update enemy
                for (game.enemies.slice()) |*enemy| {
                    const degree = random.float(f32) * std.math.tau;

                    game.particles.append(.{
                        .ttl = 0.3,
                        .type = .trail,
                        .size = 0.01,
                        .pos = toWorld(enemy.pos),
                        .vel = .init(@sin(degree), 0, @cos(degree)),
                    }) catch {};
                    const enemy_pos = toWorld(enemy.pos);
                    const enemy_direction = game.camera.position.subtract(enemy_pos).normalize();
                    enemy.projectile_cooldown -= rl.getFrameTime();

                    if (enemy.projectile_cooldown < 0 and
                        game.player_state == .alive)
                    {
                        const found_wall_on_the_way = checkCollisionWithMap(map, enemy.pos, toMap(game.camera.position), 0.001);
                        if (!found_wall_on_the_way) {
                            if (game.particles.append(.{
                                .type = .bullet,
                                .ttl = 10,
                                .pos = enemy_pos,
                                .vel = enemy_direction.scale(bullet_speed),
                                .size = 0.1,
                            })) {
                                rl.playSound(rocket_sound);
                            } else |_| {}
                            enemy.projectile_cooldown = enemy.projectile_delay;
                        }
                    }

                    if (monsters_move) { // move monsters
                        if (enemy.movement_cooldown < 0) {
                            std.log.debug("Monster wants to move", .{});
                            enemy.movement_cooldown = enemy.movement_delay;
                            const directions = [_][2]f32{
                                .{ 0, 1 },  .{ 1, 0 },
                                .{ -1, 0 }, .{ 0, -1 },
                            };
                            const dir_index = game.random.intRangeLessThan(usize, 0, directions.len);
                            const direction: @Vector(2, f32) = directions[dir_index];
                            const destenation = enemy.pos.add(@bitCast(direction));
                            if (isMapCellEmpty(map, .{ @intFromFloat(destenation.x), @intFromFloat(destenation.y) })) {
                                enemy.pos = destenation;
                                std.log.debug("Monster moved", .{});
                            }
                        }
                    }
                }
                game.enemy_spawn_cooldown -= rl.getFrameTime();
                if (game.enemy_spawn_cooldown < 0) {
                    game.enemy_spawn_cooldown = enemy_spawn_delay;
                    game.enemies.append(.{
                        .pos = (findEmptySpotOnAMap(random, map, null) orelse @panic("Cant find spot on a map")).addValue(0.5),
                        .animation_count = 4,
                        .animation_index = 0,
                    }) catch {};
                }
            }
            { // update particles
                game.spawn_cooldown -= rl.getFrameTime();
                if (rl.isMouseButtonDown(.mouse_button_left) and game.player_state == .alive) {
                    if (game.spawn_cooldown < 0) {
                        game.spawn_cooldown = player_spawn_delay;
                        if (game.particles.append(.{
                            .type = .bullet,
                            .ttl = 10,
                            .pos = game.camera.position,
                            .vel = cameraForward(game.camera).scale(bullet_speed),
                            .size = 0.1,
                        })) {
                            rl.playSound(rocket_sound);
                        } else |_| {}
                    }
                }

                var i: usize = 0;
                while (i < game.particles.len) {
                    game.particles.slice()[i].ttl -= rl.getFrameTime();
                    if (game.particles.get(i).ttl < 0) {
                        _ = game.particles.swapRemove(i);
                        continue;
                    }
                    const particle = &game.particles.slice()[i];

                    i += 1;

                    switch (particle.type) {
                        .bullet => {
                            const travel_ray = particle.vel.scale(rl.getFrameTime());
                            const destenation = particle.pos.add(travel_ray);
                            const collided_with_the_wall = checkCollisionWithMap(map, toMap(particle.pos), toMap(particle.pos.add(travel_ray)), 0.05);

                            const collided_with_floor = destenation.y < 0;
                            const collided_with_ceiling = destenation.y > 1;
                            if (collided_with_the_wall or collided_with_floor or collided_with_ceiling) {
                                rl.playSound(explosion_sound);
                                particle.* = .{
                                    .type = .explosion,
                                    .vel = .zero(),
                                    .ttl = 0.2,
                                    .size = 0,
                                    .pos = particle.pos,
                                };
                                continue;
                            } else {
                                game.particles.append(.{
                                    .ttl = 0.2,
                                    .type = .trail,
                                    .pos = particle.pos,
                                    .size = 0.01,
                                    .vel = .init(
                                        (random.float(f32) * 2 - 1) * 0.3,
                                        (random.float(f32) * 2 - 1) * 0.3,
                                        (random.float(f32) * 2 - 1) * 0.3,
                                    ),
                                }) catch {};
                                particle.pos = particle.pos.add(particle.vel.scale(rl.getFrameTime()));
                            }
                        },
                        .explosion => {
                            particle.size += 10 * rl.getFrameTime();

                            {
                                var index: usize = 0;
                                while (index < game.enemies.len) {
                                    if (rl.checkCollisionSpheres(
                                        particle.pos,
                                        particle.size,
                                        toWorld(game.enemies.slice()[index].pos),
                                        enemy_radius,
                                    )) {
                                        _ = game.enemies.swapRemove(index);
                                        game.enemies_killed += 1;
                                        if (game.enemies_killed == enemies_killed_goal) {
                                            game.player_state = .won;
                                            rl.enableCursor();
                                        }
                                        continue;
                                    }
                                    index += 1;
                                }
                            }

                            if (rl.checkCollisionSpheres(
                                particle.pos,
                                particle.size,
                                game.camera.position,
                                player_radius,
                            ) and game.player_state != .dead) {
                                const scream_index = random.intRangeLessThanBiased(usize, 0, screams.len);
                                rl.playSound(screams[scream_index]);
                                std.log.info("Player died", .{});
                                if (!invulnerability) {
                                    game.player_state = .dead;
                                }
                                game.respawn_cooldown = respawn_delay;
                            }
                        },
                        .trail => {
                            particle.pos = particle.pos.add(particle.vel.scale(rl.getFrameTime()));
                            particle.vel.y -= rl.getFrameTime() * 10;
                        },
                    }
                }
            }
        }

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.black);

        { // draw world
            game.camera.begin();
            defer game.camera.end();

            rl.drawModel(model, .init(0.5, 0, 0.5), 1, .white);

            for (game.particles.slice()) |particle| {
                switch (particle.type) {
                    .bullet => rl.drawSphere(particle.pos, particle.size, .red),
                    .explosion => rl.drawSphere(particle.pos, particle.size, .yellow),
                    .trail => {
                        rl.drawSphere(particle.pos, particle.size, .blue);
                    },
                }
            }
            for (game.enemies.slice()) |*enemy| {
                const single_width = @as(u32, @intCast(enemy_sprite.width)) / enemy.animation_count;
                const source: rl.Rectangle = .{
                    .x = @floatFromInt(single_width * enemy.animation_index),
                    .y = 0,
                    .width = @floatFromInt(single_width),
                    .height = @floatFromInt(enemy_sprite.height),
                };
                enemy.animation_index = @intFromFloat(@mod(rl.getTime() * 10, @as(f64, @floatFromInt(enemy.animation_count))));
                rl.drawBillboardRec(game.camera, enemy_sprite, source, toWorld(enemy.pos), .one(), .white);
            }
        }
        const center_x = @divFloor(rl.getScreenWidth(), 2);
        const center_y = @divFloor(rl.getScreenHeight(), 2);
        { // draw ui
            map_texture.drawEx(.init(0, 0), 0, map_scale, rl.Color.white.alpha(0.3));
            rl.drawCircleV(
                toMap(game.camera.position).scale(map_scale),
                10,
                .red,
            );

            for (potential_spawn_spots.items) |spot| {
                rl.drawCircleV(
                    spot.scale(map_scale),
                    2,
                    .yellow,
                );
            }
            for (game.enemies.slice()) |enemy| {
                rl.drawCircleV(enemy.pos.scale(map_scale), 3, .blue);
            }
            {
                var buffer: [0x100]u8 = undefined;
                const text = std.fmt.bufPrintZ(&buffer, "Killed enemies: {d}/{d}", .{ game.enemies_killed, enemies_killed_goal }) catch unreachable;
                rl.drawText(text, 10, map_scale * map.height + 10, 30, .white);
            }

            rl.drawRectangleLines(center_x - 5, center_y - 5, 10, 10, .black);

            if (game.player_state == .dead) {
                drawTextCentered("You are dead", center_x, center_y, 50, .red);
                var buffer: [0x100]u8 = undefined;
                const respawn_text = std.fmt.bufPrintZ(&buffer, "respawn in {d:0.2}", .{game.respawn_cooldown}) catch unreachable;
                drawTextCentered(respawn_text, center_x, center_y + 60, 40, .white);
            }
            if (game.player_state == .won) {
                drawTextCentered("Congratulations you won", center_x, center_y, 50, .red);

                if (rgui.guiButton(.{
                    .x = @as(f32, @floatFromInt(center_x)) - 50,
                    .y = @floatFromInt(center_y + 60),
                    .width = 100,
                    .height = 30,
                }, "Restart?") != 0) {
                    game = .init(random, map);
                    rl.disableCursor();
                }
            }
        }

        if (game.mode == .pause) {
            drawBackdrop(rl.Color.black.alpha(0.4));
            drawTextCentered(
                "Paused",
                center_x,
                @divFloor(center_y, 2),
                30,
                .white,
            );
            { // volume changer
                var volume = rl.getMasterVolume();
                var y: f32 = @as(f32, @floatFromInt(center_y)) - 50;
                const spacing = 50;
                if (rgui.guiSlider(
                    .{
                        .x = @as(f32, @floatFromInt(center_x)) - 50,
                        .y = y,
                        .width = 100,
                        .height = 30,
                    },
                    "Volume ",
                    "",
                    &volume,
                    0,
                    1,
                ) != 0) {
                    if (!rl.isSoundPlaying(explosion_sound)) {
                        rl.playSound(explosion_sound);
                    }
                    rl.setMasterVolume(volume);
                    std.log.debug("Changed volume", .{});
                }
                y += spacing;
                if (rgui.guiButton(
                    .{
                        .x = @as(f32, @floatFromInt(center_x)) - 50,
                        .y = y,
                        .width = 100,
                        .height = 30,
                    },
                    "Exit",
                ) != 0) {
                    break;
                }
                y += spacing;
            }
        }

        if (rl.isKeyPressed(.key_escape)) {
            switch (game.mode) {
                .pause => {
                    rl.disableCursor();
                    game.mode = .playing;
                },
                .playing => {
                    rl.enableCursor();
                    game.mode = .pause;
                },
            }
        }

        //     std.log.debug("frame time {d}", .{rl.getFrameTime()});
        rl.drawFPS(0, 0);
    }
}

pub fn drawTextCentered(text: [*:0]const u8, pos_x: i32, pos_y: i32, font_size: i32, color: rl.Color) void {
    const width = rl.measureText(text, font_size);
    rl.drawText(text, pos_x - @divFloor(width, 2), pos_y - @divFloor(font_size, 2), font_size, color);
}
pub fn drawBackdrop(color: rl.Color) void {
    rl.drawRectangle(0, 0, rl.getScreenWidth(), rl.getScreenHeight(), color);
}
