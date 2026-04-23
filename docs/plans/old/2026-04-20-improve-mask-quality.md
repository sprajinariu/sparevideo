
## Produced mask has insufficient quality 
1. EMA priming takes a few frames (6-7). this might not be an issue in real-life, but valuable simulation time is spent on these frames.
2. EMA priming takes a few frames even on static pictures.
3. mask produces a trail, which is then identified as a separate moving object.
4. different color moving boxes seem to produce a more pronounced trail. For example, green/blue is worse then red. 
5. dark moving box on a white background has even pronounced EMA priming, and a more pronounced trail

## Produced bbox issues
1. In the first few frames during EMA priming, noisy_moving_box produces multiple bboxes, which overlap. Is this expected behavior (limitation of CCL on working with noisy mask), or a real issue?