std = "luajit+minetest"
unused_args = false

stds.minetest = {
	read_globals = {
		"DIR_DELIM",
		"minetest",
		"dump",
		"vector",
		"nodeupdate",
		"VoxelManip",
		"VoxelArea",
		"PseudoRandom",
		"ItemStack",
		"default",
		table = {
			fields = {
				"copy",
				"key_value_swap",
			},
		},
		"bit",
	}
}

globals = {
	"castle_gates",
	"castle_masonry",
	"doc",
	"doors",
	"xpanes",
}
