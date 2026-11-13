-- Tuning values for the Stage 1 shot, shared by the server (outcome) and the client (visuals)
-- so both sides agree on goal geometry and ball flight.
--
-- World layout (studs): the goal line is the plane Z = 0, the goal is centred on X = 0,
-- the ground is Y = 0, and the shooter stands at +Z shooting towards -Z.

local ShotConfig = {}

ShotConfig.Goal = {
	Width = 30, -- inside width, post to post (oversized for readability; real ratio 3:1)
	Height = 10, -- inside height, ground to crossbar
	PostRadius = 0.4,
	NetDepth = 7,
	-- Fraction of the ball radius that must overlap the frame to count as POST;
	-- lighter touches deflect in (goal side) or out (wide side).
	FrameHitDepth = 0.5,
}

ShotConfig.Ball = {
	Radius = 1,
}

ShotConfig.ShotDistance = 40 -- goal line to ball spot

-- Positions of solid things the ball can bounce off after crossing the line.
ShotConfig.Arena = {
	BoardZ = -20, -- front face of the advertising boards / wall behind the goal
	BoardHeight = 4,
}

ShotConfig.Physics = {
	-- Lower than workspace.Gravity on purpose: weak shots get a visible loop, hard shots stay flat.
	Gravity = 55,
	MinBallSpeed = 45, -- power 0
	MaxBallSpeed = 120, -- power 1
	Drag = 0.0032, -- quadratic air drag, per stud
	Magnus = 0.022, -- curve per (rad/s * stud/s)
	SpinDecay = 0.35, -- per second
	CurlSpin = 9, -- rad/s of side spin for a shot aimed at the post (curls back towards the centre)
	DipSpin = 7, -- rad/s of top spin at full power (hard shots dip)
	SpinJitter = 1.5, -- rad/s random spin, makes no two shots identical
	GroundRestitution = 0.5,
	GroundFriction = 0.35, -- fraction of horizontal speed lost per bounce
	RollingFriction = 9, -- stud/s^2 while rolling
	FrameRestitution = 0.65, -- posts and crossbar
	NetDamping = 0.15, -- fraction of speed kept when the ball hits the net
	BoardRestitution = 0.45,
	SimStep = 1 / 240,
	SampleStep = 1 / 60,
	MaxSimTime = 3.2,
}

ShotConfig.Accuracy = {
	-- Standard deviation (studs) of the random offset from the aim point, by Shooting skill.
	ScatterAtZeroSkill = 3.2,
	ScatterAtMaxSkill = 0.6,
	MaxSigmas = 2.5, -- cap so a single shot is never wildly off
	-- Power above this threshold is less accurate and tends to rise over the bar.
	OverpowerFrom = 0.85,
	OverpowerScatter = 1.8,
	OverpowerLift = 3,
}

ShotConfig.Goalkeeper = {
	Enabled = true,
	Skill = 60, -- 0..100, opponent goalkeeper rating
	ModelScale = 1.4, -- R15 rig scale; ~7.5 studs tall next to the 10-stud goal
	HomeX = 0,
	HomeY = 4.2, -- body centre (root part) height when standing
	HomeZ = 1.6, -- stands just in front of the line
	Reach = 4.2, -- distance from the body centre the gloves cover without moving
	ReactionTime = 0.2,
	ReactionJitter = 0.06, -- +/- random part of the reaction time
	DiveSpeedAtZeroSkill = 12,
	DiveSpeedAtMaxSkill = 30,
	CatchMaxSpeed = 85, -- slower shots that reach the keeper comfortably are held, not parried
	CatchMargin = 1.5, -- studs of spare reach needed to hold the ball
}

-- Placeholder until career data exists (GDD: new players start around OVR 40).
ShotConfig.DefaultShooting = 42

-- Shot training: one guided shot that always scores, then the task (score TaskGoals in any number
-- of shots). The pass training (PassConfig) follows; after it the career goes on to the first match.
ShotConfig.Training = {
	TutorialAim = { X = 0.62, Y = 0.62 }, -- where the finger shows to press (aim coordinates)
	TutorialRingRadius = 2.6, -- studs, the ring drawn on the goal
	TutorialTapRadius = 4.5, -- studs around that point that accept the press (a bit larger than the ring)
	GuidedPowerMin = 0.55, -- the green zone on the power bar during the guided shot
	GuidedPowerMax = 0.8,
	GuidedSafeMargin = 2, -- studs kept clear of the frame and the keeper's reach on the guided shot
	GuidedKeeperDelay = 0.45, -- keeper reacts this much later on guided shots (also from an angle after a pass)
	TaskGoals = 5,
	-- Training keeper: still saves central shots, beatable in the corners.
	TaskKeeperSkill = 15,
	TaskKeeperDelay = 0.12, -- good corner shots score ~90-97%, central ones are still saved
	-- Where a new career's training starts: "SHOT" (shot training) or "PASS" (pass training).
	-- Set "PASS" to test the pass stage without replaying the shot training.
	StartStage = "SHOT",
}

ShotConfig.Episode = {
	MinThinkTime = 0.3, -- seconds between episode start and an accepted input
	Timeout = 120, -- an unanswered episode expires after this
	MinRemoteInterval = 0.2, -- per-player rate limit for remote calls
	InputTolerance = 1e-3, -- float slack allowed on input ranges
}

ShotConfig.Input = {
	PowerCycleSeconds = 1.6, -- power meter goes 0 -> 1 -> 0 over this time while held
	ReadyDelay = 0.35, -- pause after a new episode before input is accepted
}

-- Far and narrow, so the ball sits just above the bottom panel and the goal fills the middle.
ShotConfig.Camera = {
	Position = Vector3.new(0, 6, 82),
	LookAt = Vector3.new(0, 3, 0),
	FieldOfView = 28,
}

return ShotConfig
