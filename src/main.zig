const std = @import("std");

const rgui = @import("raygui");
const rl = @import("raylib");

pub fn cameraForward(camera: rl.Camera3D) rl.Vector3 {
    return camera.target.subtract(camera.position).normalize();
}

pub fn to2dPlane(vec: rl.Vector3) rl.Vector2 {
    return .{
        .x = vec.x,
        .y = vec.z,
    };
}

pub fn to3d(vec: rl.Vector2) rl.Vector3 {
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

pub fn isMapCellEmpty(map: rl.Image, coord: [2]u31) bool {
    const color = map.getColor(coord[0], coord[1]);

    return color.r == 0;
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

pub fn main() anyerror!void {
    const screenWidth = 800;
    const screenHeight = 450;
    var random_impl = std.Random.DefaultPrng.init(0);
    const random = random_impl.random();

    rl.setConfigFlags(.{
        .window_resizable = true,
        .msaa_4x_hint = true,
    });
    rl.initWindow(screenWidth, screenHeight, "raylib-zig [core] example - basic window");
    rl.setExitKey(.key_null);
    rgui.guiSetStyle(.default, 16, 25);
    rgui.guiSetStyle(.default, 1, @bitCast(rl.Color.white));
    rgui.guiSetStyle(.default, 2, @bitCast(@as(u32, 0xaaAAaaFF)));
    rl.disableCursor();
    defer rl.closeWindow();

    rl.setTargetFPS(60);

    rl.initAudioDevice();
    defer rl.closeAudioDevice();

    const rocket_sound = rl.loadSound("res/rocket.wav");
    rl.setSoundVolume(rocket_sound, 0.5);
    const explosion_sound = rl.loadSound("res/explosion.wav");
    rl.setSoundVolume(explosion_sound, 0.5);
    const map = rl.loadImage("res/cubicmap.png");
    const texture = rl.loadTexture("res/cubicmap_atlas.png"); // Load map texture
    const enemy_sprite = rl.loadTexture("res/monster.png");
    const screams = [_]rl.Sound{
        rl.loadSound("res/scream1.wav"),
        rl.loadSound("res/scream2.wav"),
    };

    const map_scale = 10;
    const player_starting_pos = findEmptySpotOnAMap(random, map, 100);
    std.debug.print("{any}\n", .{player_starting_pos});
    const map_texture = rl.loadTextureFromImage(map);
    const mesh = rl.genMeshCubicmap(map, .one());
    const model = rl.loadModelFromMesh(mesh);

    model.materials[0].maps[@intFromEnum(rl.MaterialMapIndex.material_map_albedo)].texture = texture; // Set map diffuse texture    _ = mesh; // autofix

    // Main game loop
    var camera = rl.Camera3D{
        .position = .{ .x = 1, .y = 0.5, .z = 1 },
        .target = .{ .x = 1, .y = 0, .z = 0 },
        .up = .{ .x = 0, .y = 1, .z = 0 },
        .fovy = 90,
        .projection = .camera_perspective,
    };

    if (player_starting_pos) |pos| {
        camera.position = .{
            .x = pos.x,
            .z = pos.y,
            .y = 0.5,
        };
        camera.target = camera.position.add(.{
            .x = (random.float(f32) * 2 - 1),
            .z = (random.float(f32) * 2 - 1),
            .y = 0,
        });
    }
    const bullet_speed = 10;
    var spawn_cooldown: f32 = 0;
    const player_spawn_delay = 0.2;
    var respawn_cooldown: f32 = 0;
    const enemy_spawn_delay = 2;
    var enemy_spawn_cooldown: f32 = 0;
    const respawn_delay = 5;
    const player_speed = 4;
    const player_radius = 0.3;
    const enemy_radius = 0.3;
    const camera_rotation_speed = 0.03;

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
    var particles: std.BoundedArray(Particle, 0x1000) = .{};

    var mode: enum {
        pause,
        playing,
    } = .playing;

    var player_state: enum {
        dead,
        alive,
        won,
    } = .alive;

    const Enemy = struct {
        pos: rl.Vector2,
        animation_count: u8,
        animation_index: u8,
        sprite_sheet: rl.Texture,
        projectile_cooldown: f32 = 2,
        projectile_delay: f32 = 2,
    };
    var enemies: std.BoundedArray(Enemy, 0x30) = .{};
    enemies.appendAssumeCapacity(.{
        .pos = (findEmptySpotOnAMap(random, map, null) orelse @panic("Cant find spot on a map")).addValue(0.5),
        .animation_count = 4,
        .animation_index = 0,
        .sprite_sheet = enemy_sprite,
    });
    const player_respawn_delay = 3;

    var enemies_killed: u32 = 0;
    const enemies_killed_goal = 30;

    while (!rl.windowShouldClose()) {
        if (mode == .playing and player_state != .won) {
            if (player_state == .alive) { // update player movement
                const delta = rl.getMouseDelta();
                rl.updateCameraPro(&camera, .zero(), .{
                    .x = delta.x * camera_rotation_speed,
                    .y = delta.y * camera_rotation_speed,
                    .z = 0,
                }, 0);

                const keyboard_direction = inputDirection();

                const camera_forward = cameraForward(camera);
                const camera_forward_2d = to2dPlane(camera_forward).normalize();
                const camera_right = rl.Vector2{ .x = -camera_forward_2d.y, .y = camera_forward_2d.x };

                const direction_2d = camera_forward_2d.scale(keyboard_direction.x)
                    .add(camera_right.scale(keyboard_direction.y));
                const walk_distance_this_frame = rl.getFrameTime() * player_speed;
                var dir = rl.Vector3{ .x = direction_2d.x, .y = 0, .z = direction_2d.y };
                const new_direction = for (0..3) |_| {
                    const collision = rl.getRayCollisionMesh(
                        .{
                            .position = camera.position,
                            .direction = dir,
                        },
                        mesh,
                        .identity(),
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
                camera.position = camera.position.add(camera_movement);
                camera.target = camera.target.add(camera_movement);
            } else {
                respawn_cooldown -= rl.getFrameTime();
                if (respawn_cooldown < 0) blk: {
                    player_state = .alive;

                    for (enemies.slice()) |*enemy| {
                        enemy.projectile_cooldown = player_respawn_delay;
                    }

                    const new_player_pos = findEmptySpotOnAMap(random, map, 100) orelse break :blk;
                    camera.position = .{
                        .x = new_player_pos.x,
                        .z = new_player_pos.y,
                        .y = 0.5,
                    };
                    camera.target = camera.position.add(.{
                        .x = (random.float(f32) * 2 - 1),
                        .z = (random.float(f32) * 2 - 1),
                        .y = 0,
                    });
                }
            }
            { // spawn enemy
                enemy_spawn_cooldown -= rl.getFrameTime();
                if (enemy_spawn_cooldown < 0) {
                    enemy_spawn_cooldown = enemy_spawn_delay;
                    enemies.append(.{
                        .pos = (findEmptySpotOnAMap(random, map, null) orelse @panic("Cant find spot on a map")).addValue(0),
                        .animation_count = 4,
                        .animation_index = 0,
                        .sprite_sheet = enemy_sprite,
                    }) catch {};
                }
            }
            { // update enemy
                for (enemies.slice()) |*enemy| {
                    const enemy_pos = to3d(enemy.pos);
                    const enemy_direciton = camera.position.subtract(enemy_pos).normalize();
                    const collision = rl.getRayCollisionMesh(
                        .{
                            .position = enemy_pos,
                            .direction = enemy_direciton,
                        },
                        mesh,
                        .identity(),
                    );
                    enemy.projectile_cooldown -= rl.getFrameTime();
                    if (enemy.projectile_cooldown < 0 and
                        player_state == .alive and
                        collision.hit and
                        collision.distance >= enemy_pos.distance(camera.position))
                    {
                        if (particles.append(.{
                            .type = .bullet,
                            .ttl = 10,
                            .pos = enemy_pos,
                            .vel = enemy_direciton.scale(bullet_speed),
                            .size = 0.1,
                        })) {
                            rl.playSound(rocket_sound);
                        } else |_| {}
                        enemy.projectile_cooldown = enemy.projectile_delay;
                    }
                }
                enemy_spawn_cooldown -= rl.getFrameTime();
                if (enemy_spawn_cooldown < 0) {
                    enemy_spawn_cooldown = enemy_spawn_delay;
                    enemies.append(.{
                        .pos = (findEmptySpotOnAMap(random, map, null) orelse @panic("Cant find spot on a map")).addValue(0),
                        .animation_count = 4,
                        .animation_index = 0,
                        .sprite_sheet = enemy_sprite,
                    }) catch {};
                }
            }
            { // update particles
                spawn_cooldown -= rl.getFrameTime();
                if (rl.isMouseButtonDown(.mouse_button_left) and player_state == .alive) {
                    if (spawn_cooldown < 0) {
                        spawn_cooldown = player_spawn_delay;
                        if (particles.append(.{
                            .type = .bullet,
                            .ttl = 10,
                            .pos = camera.position,
                            .vel = cameraForward(camera).scale(bullet_speed),
                            .size = 0.1,
                        })) {
                            rl.playSound(rocket_sound);
                        } else |_| {}
                    }
                }

                var i: usize = 0;
                while (i < particles.len) {
                    particles.slice()[i].ttl -= rl.getFrameTime();
                    if (particles.get(i).ttl < 0) {
                        _ = particles.swapRemove(i);
                        continue;
                    }
                    const particle = &particles.slice()[i];

                    i += 1;

                    switch (particle.type) {
                        .bullet => {
                            const travel_ray = particle.vel.scale(rl.getFrameTime());
                            const collision = rl.getRayCollisionMesh(
                                .{
                                    .position = particle.pos,
                                    .direction = travel_ray.normalize(),
                                },
                                mesh,
                                .identity(),
                            );

                            if (collision.hit and collision.distance <= travel_ray.length()) {
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
                                particles.append(.{
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
                                while (index < enemies.len) {
                                    if (rl.checkCollisionSpheres(
                                        particle.pos,
                                        particle.size,
                                        to3d(enemies.slice()[index].pos),
                                        enemy_radius,
                                    )) {
                                        _ = enemies.swapRemove(index);
                                        enemies_killed += 1;
                                        if (enemies_killed == enemies_killed_goal) {
                                            player_state = .won;
                                        }
                                        continue;
                                    }
                                    index += 1;
                                }
                            }

                            if (rl.checkCollisionSpheres(
                                particle.pos,
                                particle.size,
                                camera.position,
                                player_radius,
                            ) and player_state != .dead) {
                                const scream_index = random.intRangeLessThanBiased(usize, 0, screams.len);
                                rl.playSound(screams[scream_index]);
                                std.log.info("Player died", .{});
                                player_state = .dead;
                                respawn_cooldown = respawn_delay;
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
            camera.begin();
            defer camera.end();

            rl.drawModel(model, .zero(), 1, .white);

            for (particles.slice()) |particle| {
                switch (particle.type) {
                    .bullet => rl.drawSphere(particle.pos, particle.size, .red),
                    .explosion => rl.drawSphere(particle.pos, particle.size, .yellow),
                    .trail => {
                        rl.drawSphere(particle.pos, particle.size, .blue);
                    },
                }
            }
            for (enemies.slice()) |*enemy| {
                const single_width = @as(u32, @intCast(enemy.sprite_sheet.width)) / enemy.animation_count;
                const source: rl.Rectangle = .{
                    .x = @floatFromInt(single_width * enemy.animation_index),
                    .y = 0,
                    .width = @floatFromInt(single_width),
                    .height = @floatFromInt(enemy.sprite_sheet.height),
                };
                enemy.animation_index = @intFromFloat(@mod(rl.getTime() * 10, @as(f64, @floatFromInt(enemy.animation_count))));
                rl.drawBillboardRec(camera, enemy.sprite_sheet, source, to3d(enemy.pos), .one(), .white);
            }
        }
        const center_x = @divFloor(rl.getScreenWidth(), 2);
        const center_y = @divFloor(rl.getScreenHeight(), 2);
        { // draw ui
            map_texture.drawEx(.init(0, 0), 0, map_scale, rl.Color.white.alpha(0.3));
            rl.drawCircleV(
                to2dPlane(camera.position).scale(map_scale),
                10,
                .red,
            );
            for (enemies.slice()) |enemy| {
                rl.drawCircleV(enemy.pos.addValue(0.5).scale(map_scale), 3, .blue);
            }
            {
                var buffer: [0x100]u8 = undefined;
                const text = std.fmt.bufPrintZ(&buffer, "Killed enemies: {d}/{d}", .{ enemies_killed, enemies_killed_goal }) catch unreachable;
                rl.drawText(text, 10, map_scale * map.height + 10, 30, .white);
            }

            rl.drawRectangleLines(center_x - 5, center_y - 5, 10, 10, .black);

            if (player_state == .dead) {
                drawTextCentered("You are dead", center_x, center_y, 50, .red);
                var buffer: [0x100]u8 = undefined;
                const respawn_text = std.fmt.bufPrintZ(&buffer, "respawn in {d:0.2}", .{respawn_cooldown}) catch unreachable;
                drawTextCentered(respawn_text, center_x, center_y + 60, 40, .white);
            }
            if (player_state == .won) {
                drawTextCentered("Congratulations you won", center_x, center_y, 50, .red);
                // if (rgui.guiButton("Restart") != 0) {}
            }
        }

        if (mode == .pause) {
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
            switch (mode) {
                .pause => {
                    rl.disableCursor();
                    mode = .playing;
                },
                .playing => {
                    rl.enableCursor();
                    mode = .pause;
                },
            }
        }

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
