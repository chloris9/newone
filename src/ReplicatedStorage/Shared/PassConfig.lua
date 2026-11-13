-- Tuning for the Stage 2 pass, shared by the server (outcome) and the client (visuals).
--
-- The pass is played on the same pitch as the shot, further from the goal: the passer stands at
-- Origin and passes along the ground (Y is ignored) towards teammates nearer the goal (-Z).

local PassConfig = {}

PassConfig.Origin = Vector3.new(0, 0, 66) -- ball at the passer's feet

-- Higher, steeper camera than the shot so the whole move fits on screen.
PassConfig.Camera = {
	Position = Vector3.new(0, 48, 110),
	LookAt = Vector3.new(0, 0, 58), -- ball at ~60% of the screen height, clear of the bottom panel on phones
	FieldOfView = 42,
}

PassConfig.Ball = {
	Friction = 20, -- stud/s^2, rolling deceleration
	-- The ball is played to stop this far past the release point, so it arrives with some pace.
	Overrun = 6,
	MinRange = 8, -- shorter drags don't pass (accidental taps)
	MaxRange = 50, -- drag length for 100% power
}

PassConfig.Teammate = {
	Reach = 2.2, -- studs from the body that the foot covers
	Speed = 12, -- stud/s when stepping to the ball
	Reaction = 0.12,
	MaxMove = 4, -- how far a teammate comes off his spot for a pass
	ControlMaxSpeed = 25, -- faster balls bounce off ("too hard")
}

PassConfig.Defender = {
	Reach = 2.4, -- includes the lunge
	Speed = 10,
	Reaction = 0.32, -- after the pass is played
	ReactionJitter = 0.05,
}

PassConfig.Accuracy = {
	-- Standard deviation of the direction error (degrees) and distance error (fraction), by Passing skill.
	AngleAtZeroSkill = 6,
	AngleAtMaxSkill = 1,
	DistanceAtZeroSkill = 0.1,
	DistanceAtMaxSkill = 0.02,
	MaxSigmas = 2.5,
}

-- Placeholder until career data exists.
PassConfig.DefaultPassing = 45

-- Prepared situations, relative to Origin (studs; -Z is towards the goal). The defender walks back
-- and forth between `from` and `to`; where he is when the pass is played is up to the player.
PassConfig.Layouts = {
	-- 1: tutorial. Left teammate free, defender out on the right.
	{ teammates = { { -14, -18 }, { 18, -26 } }, defender = { from = { 12, -12 }, to = { 20, -12 }, speed = 4 } },
	-- 2: left free, right lane patrolled.
	{ teammates = { { -16, -20 }, { 18, -26 } }, defender = { from = { -2, -13 }, to = { 11, -13 }, speed = 6 } },
	-- 3: short pass is easy, the long one needs timing.
	{ teammates = { { -12, -12 }, { 10, -34 } }, defender = { from = { -6, -21 }, to = { 10, -21 }, speed = 7 } },
	-- 4: defender in the middle covers both lanes in turn.
	{ teammates = { { -19, -23 }, { 19, -23 } }, defender = { from = { -10, -12 }, to = { 10, -12 }, speed = 8 } },
	-- 5: through ball or a safe square pass.
	{ teammates = { { -6, -32 }, { 20, -12 } }, defender = { from = { -12, -20 }, to = { 4, -20 }, speed = 6 } },
}

PassConfig.Training = {
	TutorialLayout = 1,
	TutorialTarget = 1, -- teammate the finger shows
	RingRadius = 4.2, -- studs, the ring around that teammate
	TapRadius = 7, -- releases this close to him count on the guided pass
	TaskPasses = 5, -- good passes needed (any number of attempts)
}

PassConfig.SimStep = 1 / 120
PassConfig.SampleStep = 1 / 60

return PassConfig
