-- old gates used node metadata to store the moving direction
minetest.register_lbm({
    label = "remove metadata from old castle_gates doors",
    name = "castle_gates:remove_node_meta",
    nodenames = {"group:castle_gate"},
    run_at_every_load = false,
    action = function (pos)
        minetest.get_meta(pos):set_string("previous_move", "")
    end
})