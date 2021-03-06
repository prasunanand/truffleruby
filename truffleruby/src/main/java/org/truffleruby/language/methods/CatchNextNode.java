/*
 * Copyright (c) 2013, 2017 Oracle and/or its affiliates. All rights reserved. This
 * code is released under a tri EPL/GPL/LGPL license. You can use it,
 * redistribute it and/or modify it under the terms of the:
 *
 * Eclipse Public License version 1.0
 * GNU General Public License version 2
 * GNU Lesser General Public License version 2.1
 */
package org.truffleruby.language.methods;

import com.oracle.truffle.api.frame.VirtualFrame;
import com.oracle.truffle.api.profiles.BranchProfile;
import org.truffleruby.language.RubyNode;
import org.truffleruby.language.control.NextException;

public class CatchNextNode extends RubyNode {

    @Child private RubyNode body;

    private final BranchProfile nextProfile = BranchProfile.create();

    public CatchNextNode(RubyNode body) {
        this.body = body;
    }

    @Override
    public Object execute(VirtualFrame frame) {
        try {
            return body.execute(frame);
        } catch (NextException e) {
            nextProfile.enter();
            return e.getResult();
        }
    }

}
