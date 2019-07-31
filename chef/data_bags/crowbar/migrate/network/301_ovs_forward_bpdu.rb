def upgrade(tattr, tdep, attr, dep)
  unless attr["networks"]["nova_fixed"].key? "ovs_forward_bpdu"
    attr["networks"]["nova_fixed"]["ovs_forward_bpdu"] = tattr["networks"]["nova_fixed"]["ovs_forward_bpdu"]
  end

  unless attr["networks"]["nova_floating"].key? "ovs_forward_bpdu"
    attr["networks"]["nova_floating"]["ovs_forward_bpdu"] = tattr["networks"]["nova_floating"]["ovs_forward_bpdu"]
  end

  return attr, dep
end

def downgrade(tattr, tdep, attr, dep)
  unless tattr["networks"]["nova_fixed"].key? "ovs_forward_bpdu"
    attr["networks"]["nova_fixed"].delete "ovs_forward_bpdu"
  end

  unless tattr["networks"]["nova_floating"].key? "ovs_forward_bpdu"
    attr["networks"]["nova_floating"].delete "ovs_forward_bpdu"
  end

  return attr, dep
end
