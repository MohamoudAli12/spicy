package spicy

// The model parameters of VACASK's SPICE devices, aliases included (generated from the
// device sources of VACASK 0.3.4, devices/spice/*.va, by tools/vacask_params.py: the
// parameters that are not instance parameters). A model card's parameter that is not in
// its device's list is left out of the VACASK netlist, as ngspice leaves it out: VACASK
// would stop at it.

@(private = "file")
SP_BJT_PARAMS := []string{"af", "bf", "br", "c2", "c4", "ccs", "cjc", "cje", "cjs", "cn", "csub", "ctc", "cte", "cts", "d", "eg", "fc", "gamma", "ib_max", "ibc", "ibe", "ic_max", "ik", "ikf", "ikr", "irb", "is", "isc", "ise", "iss", "itf", "kf", "mc", "me", "mjc", "mje", "mjs", "ms", "nc", "ne", "nf", "nk", "nkf", "nr", "ns", "pc", "pd_max", "pe", "ps", "ptf", "qco", "quasimod", "rb", "rbm", "rc", "rco", "re", "rth0", "subs", "tbf1", "tbf2", "tbr1", "tbr2", "te_max", "tf", "tikf1", "tikf2", "tikr1", "tikr2", "tirb1", "tirb2", "tis1", "tis2", "tisc1", "tisc2", "tise1", "tise2", "tiss1", "tiss2", "titf1", "titf2", "tlev", "tlevc", "tmjc1", "tmjc2", "tmje1", "tmje2", "tmjs1", "tmjs2", "tnc1", "tnc2", "tne1", "tne2", "tnf1", "tnf2", "tnom", "tnr1", "tnr2", "tns1", "tns2", "tr", "trb", "trb1", "trb2", "trc", "trc1", "trc2", "tre", "tre1", "tre2", "tref", "trm1", "trm2", "ttf1", "ttf2", "ttr1", "ttr2", "tvaf1", "tvaf2", "tvar1", "tvar2", "tvjc", "tvje", "tvjs", "type", "va", "vaf", "var", "vb", "vbc_max", "vbe_max", "vce_max", "vg", "vjc", "vje", "vjs", "vo", "vtf", "xcjc", "xtb", "xtf", "xti"}

@(private = "file")
SP_JFET1_PARAMS := []string{"af", "b", "beta", "betatce", "bex", "cgd", "cgs", "eg", "fc", "gdsnoi", "is", "kf", "lambda", "n", "nlev", "pb", "rd", "rs", "tcv", "tnom", "type", "vt0", "vto", "vtotc", "xti"}

@(private = "file")
SP_JFET2_PARAMS := []string{"acgam", "af", "beta", "cds", "cgd", "cgs", "delta", "fc", "hfe1", "hfe2", "hfeta", "hfg1", "hfg2", "hfgam", "ibd", "is", "kf", "lambda", "lfg1", "lfg2", "lfgam", "mvst", "mxi", "n", "p", "pb", "q", "rd", "rs", "taud", "taug", "tnom", "type", "vbd", "vbi", "ver", "vst", "vt0", "vto", "xc", "xi", "z"}

@(private = "file")
SP_VDMOS_PARAMS := []string{"a", "af", "bex", "bv", "cgdmax", "cgdmin", "cgs", "cjo", "cthj", "derating", "eg", "fc", "ibv", "id_max", "idr_max", "is", "kf", "kp", "ksubthres", "lambda", "m", "mtriode", "mu", "n", "nbv", "pd_max", "phi", "qpscale", "rb", "rd", "rds", "rg", "rq", "rs", "rth_ext", "rthca", "rthjc", "subshift", "tcvth", "te_max", "texp0", "texp1", "theta", "tksubthres1", "tksubthres2", "tm1", "tm2", "tnom", "trb1", "trb2", "trd1", "trd2", "trg1", "trg2", "trs1", "trs2", "tt", "ttt1", "ttt2", "type", "vdmos", "vds_max", "vgd_max", "vgdr_max", "vgs_max", "vgsr_max", "vj", "vp", "vq", "vth0", "vto", "vtotc", "xti"}

@(private = "file")
SP_MOS1_PARAMS := []string{"af", "cbd", "cbs", "cgbo", "cgdo", "cgso", "cj", "cjsw", "fc", "gamma", "gdsnoi", "is", "js", "kf", "kp", "lambda", "ld", "mj", "mjsw", "nlev", "nss", "nsub", "pb", "phi", "rd", "rs", "rsh", "tnom", "tox", "tpg", "type", "u0", "uo", "vt0", "vto"}

@(private = "file")
SP_MOS2_PARAMS := []string{"af", "cbd", "cbs", "cgbo", "cgdo", "cgso", "cj", "cjsw", "delta", "fc", "gamma", "gdsnoi", "is", "js", "kf", "kp", "lambda", "ld", "mj", "mjsw", "neff", "nfs", "nlev", "nss", "nsub", "pb", "phi", "rd", "rs", "rsh", "tnom", "tox", "tpg", "type", "u0", "ucrit", "uexp", "uo", "vmax", "vt0", "vto", "xj"}

@(private = "file")
SP_MOS3_PARAMS := []string{"af", "cbd", "cbs", "cgbo", "cgdo", "cgso", "cj", "cjsw", "delta", "delvt0", "delvto", "eta", "fc", "gamma", "gdsnoi", "is", "js", "kappa", "kf", "kp", "ld", "mj", "mjsw", "nfs", "nlev", "nss", "nsub", "pb", "phi", "rd", "rs", "rsh", "theta", "tnom", "tox", "tpg", "type", "u0", "uo", "vmax", "vt0", "vto", "wd", "xj", "xl", "xw"}

@(private = "file")
SP_MOS6_PARAMS := []string{"af", "cbd", "cbs", "cgbo", "cgdo", "cgso", "cj", "cjsw", "fc", "gamma", "gamma1", "is", "js", "kc", "kf", "kv", "lambda", "lambda0", "lambda1", "ld", "mj", "mjsw", "nc", "nlev", "nss", "nsub", "nv", "nvth", "pb", "phi", "ps_mod", "rd", "rs", "rsh", "sigma", "tnom", "tox", "tpg", "type", "u0", "uo", "vt0", "vto"}

@(private = "file")
SP_MOS9_PARAMS := []string{"af", "cbd", "cbs", "cgbo", "cgdo", "cgso", "cj", "cjsw", "delta", "delvt0", "delvto", "eta", "fc", "gamma", "is", "js", "kappa", "kf", "kp", "ld", "mj", "mjsw", "nfs", "nss", "nsub", "pb", "phi", "rd", "rs", "rsh", "theta", "tnom", "tox", "tpg", "type", "u0", "uo", "vmax", "vt0", "vto", "wd", "xj", "xl", "xw"}

vacask_model_params :: proc(module: string) -> []string {
	switch module {
	case "sp_bjt": return SP_BJT_PARAMS
	case "sp_jfet1": return SP_JFET1_PARAMS
	case "sp_jfet2": return SP_JFET2_PARAMS
	case "sp_vdmos": return SP_VDMOS_PARAMS
	case "sp_mos1": return SP_MOS1_PARAMS
	case "sp_mos2": return SP_MOS2_PARAMS
	case "sp_mos3": return SP_MOS3_PARAMS
	case "sp_mos6": return SP_MOS6_PARAMS
	case "sp_mos9": return SP_MOS9_PARAMS
	}
	return nil
}
